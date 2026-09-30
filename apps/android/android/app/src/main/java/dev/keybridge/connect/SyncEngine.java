package dev.keybridge.connect;

import java.io.*;
import java.net.*;
import java.security.*;
import java.security.cert.X509Certificate;
import javax.net.ssl.*;
import org.json.*;

final class SyncEngine {
  final Vault vault;
  final boolean test;
  private JSONObject invitation, pairRequest;
  private String deviceId, comparison;
  private boolean busy;
  boolean dropAckConfirmationForTest;

  SyncEngine(Vault v, boolean test) {
    vault = v;
    this.test = BuildConfig.DEBUG && test;
  }

  static final class Response {
    final int code;
    final JSONObject body;

    Response(int c, JSONObject b) {
      code = c;
      body = b;
    }
  }

  Response post(JSONObject pair, String path, JSONObject body) throws Exception {
    URI base = Protocol.endpoint(pair.getString("url"), test);
    byte[] pin = Protocol.binary(pair.getString("certificateSha256"), 32);
    X509TrustManager trust =
        new X509TrustManager() {
          public X509Certificate[] getAcceptedIssuers() {
            return new X509Certificate[0];
          }

          public void checkClientTrusted(X509Certificate[] c, String t)
              throws java.security.cert.CertificateException {
            throw new java.security.cert.CertificateException();
          }

          public void checkServerTrusted(X509Certificate[] chain, String auth)
              throws java.security.cert.CertificateException {
            try {
              Protocol.check(
                  chain.length > 0
                      && MessageDigest.isEqual(pin, Protocol.hash(chain[0].getEncoded())));
              chain[0].checkValidity();
            } catch (Exception e) {
              throw new java.security.cert.CertificateException("certificate_mismatch");
            }
          }
        };
    SSLContext tls = SSLContext.getInstance("TLS");
    tls.init(null, new TrustManager[] {trust}, null);
    HttpsURLConnection c =
        (HttpsURLConnection) base.resolve(path).toURL().openConnection(Proxy.NO_PROXY);
    c.setSSLSocketFactory(tls.getSocketFactory());
    c.setHostnameVerifier(
        (host, session) -> {
          try {
            return MessageDigest.isEqual(
                pin, Protocol.hash(session.getPeerCertificates()[0].getEncoded()));
          } catch (Exception e) {
            return false;
          }
        });
    c.setInstanceFollowRedirects(false);
    c.setConnectTimeout(10000);
    c.setReadTimeout(15000);
    c.setRequestMethod("POST");
    c.setRequestProperty("Content-Type", "application/json");
    c.setRequestProperty("Connection", "close");
    c.setDoOutput(true);
    byte[] bytes = Protocol.bytes(body.toString());
    Protocol.check(bytes.length <= 256 * 1024);
    c.setFixedLengthStreamingMode(bytes.length);
    try {
      c.connect();
      Protocol.check(
          MessageDigest.isEqual(pin, Protocol.hash(c.getServerCertificates()[0].getEncoded())));
      try (OutputStream out = c.getOutputStream()) {
        out.write(bytes);
      }
      int status = c.getResponseCode();
      Protocol.check(c.getContentLengthLong() <= Protocol.MAX_WIRE);
      InputStream input = status >= 400 ? c.getErrorStream() : c.getInputStream();
      Protocol.check(input != null);
      ByteArrayOutputStream output = new ByteArrayOutputStream();
      byte[] b = new byte[8192];
      long deadline = System.nanoTime() + 15000000000L;
      try (InputStream in = input) {
        int n;
        while ((n = in.read(b)) != -1) {
          Protocol.check(output.size() + n <= Protocol.MAX_WIRE && System.nanoTime() < deadline);
          output.write(b, 0, n);
        }
      }
      return new Response(status, Protocol.parse(output.toByteArray(), Protocol.MAX_WIRE));
    } finally {
      c.disconnect();
    }
  }

  synchronized JSONObject beginPair(String code) throws Exception {
    Protocol.check(vault.unlocked() && !busy && !vault.read().has("staged"));
    invitation = Protocol.invitation(code, test);
    deviceId = java.util.UUID.randomUUID().toString();
    byte[] nonce = Protocol.random(32),
        secret = Protocol.binary(invitation.getString("secret"), 32),
        input = new byte[64];
    System.arraycopy(secret, 0, input, 0, 32);
    System.arraycopy(nonce, 0, input, 32, 32);
    byte[] hash = Protocol.hash(input);
    long value =
        ((hash[0] & 255L) << 24)
            | ((hash[1] & 255L) << 16)
            | ((hash[2] & 255L) << 8)
            | (hash[3] & 255L);
    comparison = String.format(java.util.Locale.ROOT, "%06d", value % 1000000);
    pairRequest =
        Protocol.seal(
            Protocol.obj(
                "version",
                1,
                "vaultId",
                invitation.getString("vaultId"),
                "deviceId",
                deviceId,
                "deviceName",
                "Keybridge Android",
                "clientNonce",
                Protocol.b64(nonce)),
            secret,
            Protocol.aad(
                "pair-request", invitation.getString("vaultId"), invitation.getString("pairId")));
    return Protocol.obj(
        "comparison", comparison, "desktopName", invitation.getString("desktopName"));
  }

  synchronized JSONObject pollPair() throws Exception {
    Protocol.check(
        invitation != null && invitation.getLong("expiresAt") > System.currentTimeMillis() / 1000);
    Response r = post(invitation, "/v1/pair/" + invitation.getString("pairId"), pairRequest);
    if (r.code == 202) return Protocol.obj("status", "pending");
    Protocol.check(r.code == 200);
    JSONObject approved =
        Protocol.unseal(
            r.body,
            Protocol.binary(invitation.getString("secret"), 32),
            Protocol.aad(
                "pair-response", invitation.getString("vaultId"), invitation.getString("pairId")));
    Protocol.check(
        Protocol.number(approved, "version") == 1
            && deviceId.equals(approved.getString("deviceId"))
            && invitation.getString("vaultId").equals(approved.getString("vaultId")));
    Protocol.binary(approved.getString("syncKey"), 32);
    for (String k : new String[] {"url", "publicKey", "certificateSha256"})
      approved.put(k, invitation.get(k));
    JSONObject next = vault.read();
    Protocol.check(!next.has("staged"));
    next.put("staged", Protocol.obj("pairing", approved));
    vault.commit(next);
    invitation = null;
    pairRequest = null;
    return Protocol.obj("status", "approved");
  }

  JSONObject envelope(JSONObject pair, String kind, JSONObject plain) throws Exception {
    JSONObject box =
        Protocol.seal(
            plain,
            Protocol.derive(
                Protocol.binary(pair.getString("syncKey"), 32),
                pair.getString("vaultId"),
                pair.getString("deviceId"),
                "c2s"),
            Protocol.aad(kind + "-request", pair.getString("vaultId"), pair.getString("deviceId")));
    box.put("deviceId", pair.getString("deviceId"));
    return box;
  }

  JSONObject decode(JSONObject pair, String kind, JSONObject box) throws Exception {
    return Protocol.unseal(
        box,
        Protocol.derive(
            Protocol.binary(pair.getString("syncKey"), 32),
            pair.getString("vaultId"),
            pair.getString("deviceId"),
            "s2c"),
        Protocol.aad(kind + "-response", pair.getString("vaultId"), pair.getString("deviceId")));
  }

  synchronized JSONObject sync() throws Exception {
    Protocol.check(!busy);
    busy = true;
    try {
      JSONObject state = vault.read();
      String slot = state.has("staged") ? "staged" : "active";
      JSONObject local = state.getJSONObject(slot);
      JSONObject pair = local.getJSONObject("pairing");
      if (local.has("pendingReceipt")) {
        if (ack(slot, local)) return Protocol.obj("status", "synced");
      }
      state = vault.read();
      local = state.getJSONObject(slot);
      long generation =
          local.has("snapshot") ? local.getJSONObject("snapshot").getLong("generation") : 0;
      String digest = local.optString("digest", "");
      String request = Protocol.b64(Protocol.random(32));
      JSONObject plain =
          Protocol.obj(
              "version",
              1,
              "vaultId",
              pair.getString("vaultId"),
              "deviceId",
              pair.getString("deviceId"),
              "requestId",
              request,
              "lastGeneration",
              generation,
              "lastDigest",
              digest);
      Response response = post(pair, "/v1/sync", envelope(pair, "sync", plain));
      Protocol.check(response.code == 200);
      JSONObject content = decode(pair, "sync", response.body);
      if ("unchanged".equals(content.optString("status"))) {
        Protocol.check(
            Protocol.number(content, "version") == 1
                && request.equals(content.getString("requestId"))
                && generation == Protocol.number(content, "generation")
                && digest.equals(content.getString("snapshotSha256")));
      } else {
        JSONObject verified = Protocol.verify(content, pair, request, generation, digest);
        local.put("snapshot", verified.getJSONObject("snapshot"));
        local.put("digest", verified.getString("digest"));
        generation = local.getJSONObject("snapshot").getLong("generation");
        digest = local.getString("digest");
      }
      local.put(
          "pendingReceipt",
          Protocol.obj(
              "version",
              1,
              "vaultId",
              pair.getString("vaultId"),
              "deviceId",
              pair.getString("deviceId"),
              "requestId",
              request,
              "generation",
              generation,
              "snapshotSha256",
              digest,
              "status",
              "committed"));
      state.put(slot, local);
      vault.commit(state);
      Protocol.check(ack(slot, local));
      return Protocol.obj("status", "synced");
    } finally {
      busy = false;
    }
  }

  boolean ack(String slot, JSONObject local) throws Exception {
    JSONObject pair = local.getJSONObject("pairing"),
        receipt = local.getJSONObject("pendingReceipt");
    Response r = post(pair, "/v1/ack", envelope(pair, "ack", receipt));
    if (r.code == 400) return false;
    Protocol.check(r.code == 200);
    if (BuildConfig.DEBUG && dropAckConfirmationForTest) {
      dropAckConfirmationForTest = false;
      throw new IOException("injected_lost_ack_confirmation");
    }
    JSONObject confirmation = decode(pair, "ack", r.body);
    Protocol.check(
        Protocol.number(confirmation, "version") == 1
            && "recorded".equals(confirmation.getString("status")));
    Protocol.check(
        Protocol.number(receipt, "generation") == Protocol.number(confirmation, "generation"));
    for (String k : new String[] {"vaultId", "deviceId", "requestId", "snapshotSha256"})
      Protocol.check(receipt.get(k).equals(confirmation.get(k)));
    JSONObject next = vault.read();
    local.remove("pendingReceipt");
    local.put("confirmedAt", System.currentTimeMillis() / 1000);
    next.put("active", local);
    if (slot.equals("staged")) {
      next.remove("staged");
      next.put("associations", new JSONArray());
    }
    vault.commit(next);
    return true;
  }

  synchronized void cancelUncommittedReplacement() throws Exception {
    JSONObject state = vault.read();
    JSONObject staged = state.optJSONObject("staged");
    if (staged == null) return;
    Protocol.check(!staged.has("pendingReceipt") && !staged.has("snapshot"));
    state.remove("staged");
    vault.commit(state);
  }

  synchronized void cancelPair() {
    invitation = null;
    pairRequest = null;
  }
}
