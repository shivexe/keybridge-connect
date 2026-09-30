package dev.keybridge.connect;

import android.content.Context;
import java.net.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import okhttp3.*;
import org.json.*;

final class AssetLinks {
  static boolean publicAddress(InetAddress address) {
    if (address.isAnyLocalAddress()
        || address.isLoopbackAddress()
        || address.isLinkLocalAddress()
        || address.isSiteLocalAddress()
        || address.isMulticastAddress()) return false;
    byte[] b = address.getAddress();
    int a = b[0] & 255, z = b[1] & 255;
    if (b.length == 4)
      return a > 0
          && a < 224
          && a != 127
          && !(a == 100 && z >= 64 && z <= 127)
          && !(a == 169 && z == 254)
          && !(a == 192 && (z == 0 || z == 168))
          && !(a == 198 && (z == 18 || z == 19 || z == 51))
          && !(a == 203 && z == 0 && (b[2] & 255) == 113);
    return (a & 224) == 32
        && !(a == 32
            && z == 1
            && ((b[2] & 255) == 13 && (b[3] & 255) == 184
                || (b[2] & 255) == 0 && (b[3] & 255) == 0))
        && !(a == 32 && z == 2);
  }

  static boolean verify(Context context, String origin, String pkg, String expectedSignature)
      throws Exception {
    String host = Matcher.host(origin);
    Protocol.check(!host.isEmpty());
    List<InetAddress> addresses = Arrays.asList(InetAddress.getAllByName(host));
    Protocol.check(!addresses.isEmpty());
    for (InetAddress a : addresses) Protocol.check(publicAddress(a));
    OkHttpClient client =
        new OkHttpClient.Builder()
            .proxy(Proxy.NO_PROXY)
            .dns(
                name -> {
                  if (!name.equals(host)) throw new UnknownHostException("origin_mismatch");
                  return addresses;
                })
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS)
            .callTimeout(10, TimeUnit.SECONDS)
            .build();
    Request request =
        new Request.Builder().url("https://" + host + "/.well-known/assetlinks.json").get().build();
    try (Response response = client.newCall(request).execute()) {
      Protocol.check(
          response.code() == 200
              && response.body() != null
              && response.body().contentLength() <= 256 * 1024);
      byte[] data;
      try (java.io.InputStream in = response.body().byteStream();
          java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream()) {
        byte[] buffer = new byte[4096];
        int n;
        while ((n = in.read(buffer)) != -1) {
          Protocol.check(out.size() + n <= 256 * 1024);
          out.write(buffer, 0, n);
        }
        data = out.toByteArray();
      }
      java.io.ByteArrayOutputStream wrappedBytes = new java.io.ByteArrayOutputStream();
      wrappedBytes.write(Protocol.bytes("{\"links\":"));
      wrappedBytes.write(data);
      wrappedBytes.write(Protocol.bytes("}"));
      JSONObject wrapped = Protocol.parse(wrappedBytes.toByteArray(), 256 * 1024 + 32);
      JSONArray links = wrapped.getJSONArray("links");
      Protocol.check(expectedSignature.equals(Matcher.fingerprint(context, pkg)));
      for (int i = 0; i < links.length(); i++) {
        JSONObject link = links.getJSONObject(i), target = link.optJSONObject("target");
        if (target == null
            || !"android_app".equals(target.optString("namespace"))
            || !pkg.equals(target.optString("package_name"))) continue;
        JSONArray relation = link.optJSONArray("relation");
        boolean allowed = false;
        if (relation != null)
          for (int j = 0; j < relation.length(); j++)
            if ("delegate_permission/common.get_login_creds".equals(relation.optString(j)))
              allowed = true;
        if (!allowed) continue;
        JSONArray fingerprints = target.getJSONArray("sha256_cert_fingerprints");
        Set<String> approved = new HashSet<>();
        for (int j = 0; j < fingerprints.length(); j++) {
          String hex = fingerprints.getString(j).replace(":", "");
          Protocol.check(hex.matches("[0-9a-fA-F]{64}"));
          byte[] bytes = new byte[32];
          for (int k = 0; k < 32; k++)
            bytes[k] = (byte) Integer.parseInt(hex.substring(k * 2, k * 2 + 2), 16);
          approved.add(Protocol.b64(bytes));
        }
        if (approved.containsAll(Arrays.asList(expectedSignature.split(",")))) return true;
      }
      return false;
    } finally {
      client.connectionPool().evictAll();
      client.dispatcher().executorService().shutdown();
    }
  }
}
