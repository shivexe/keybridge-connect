package dev.keybridge.connect;

import android.util.Base64;
import com.google.gson.Strictness;
import com.google.gson.stream.JsonReader;
import com.google.gson.stream.JsonToken;
import java.io.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.*;
import java.security.*;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.*;
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters;
import org.bouncycastle.crypto.signers.Ed25519Signer;
import org.json.*;

public final class Protocol {
  static final int MAX_WIRE = 32 * 1024 * 1024, MAX_BODY = 8 * 1024 * 1024;
  static final long MAX_INTEGER = 9007199254740991L;
  static final SecureRandom RANDOM = new SecureRandom();

  static void check(boolean value) {
    if (!value) throw new IllegalArgumentException("invalid_data");
  }

  static byte[] random(int n) {
    byte[] b = new byte[n];
    RANDOM.nextBytes(b);
    return b;
  }

  static String b64(byte[] bytes) {
    return Base64.encodeToString(bytes, Base64.NO_WRAP);
  }

  static byte[] bytes(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  static byte[] binary(String s, int size) {
    check(s.length() <= MAX_WIRE);
    byte[] b = Base64.decode(s, Base64.NO_WRAP);
    check(b64(b).equals(s) && (size < 0 || b.length == size));
    return b;
  }

  static byte[] hash(byte[] b) throws Exception {
    return MessageDigest.getInstance("SHA-256").digest(b);
  }

  static JSONObject obj(Object... args) throws Exception {
    JSONObject j = new JSONObject();
    for (int i = 0; i < args.length; i += 2) j.put((String) args[i], args[i + 1]);
    return j;
  }

  static JSONObject copy(JSONObject j) throws Exception {
    return parse(bytes(j.toString()), MAX_WIRE);
  }

  static boolean id(String s) {
    return s.matches("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}");
  }

  static long number(JSONObject j, String k) throws Exception {
    Object n = j.get(k);
    check(n instanceof Integer || n instanceof Long);
    long v = ((Number) n).longValue();
    check(v >= 0 && v <= MAX_INTEGER);
    return v;
  }

  static String text(JSONObject j, String k) throws Exception {
    Object v = j.get(k);
    check(v instanceof String);
    return (String) v;
  }

  static JSONObject parse(byte[] b, int limit) throws Exception {
    check(b.length <= limit);
    String s =
        StandardCharsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(b))
            .toString();
    JsonReader r = new JsonReader(new StringReader(s));
    r.setStrictness(Strictness.STRICT);
    scan(r, 0);
    check(r.peek() == JsonToken.END_DOCUMENT);
    return new JSONObject(s);
  }

  static void unicode(String s) {
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (Character.isHighSurrogate(c)) {
        check(++i < s.length() && Character.isLowSurrogate(s.charAt(i)));
      } else check(!Character.isLowSurrogate(c));
    }
  }

  static void scan(JsonReader r, int depth) throws Exception {
    check(depth <= 24);
    switch (r.peek()) {
      case BEGIN_OBJECT:
        r.beginObject();
        Set<String> names = new HashSet<>();
        while (r.hasNext()) {
          String n = r.nextName();
          unicode(n);
          check(names.add(n));
          scan(r, depth + 1);
        }
        r.endObject();
        break;
      case BEGIN_ARRAY:
        r.beginArray();
        while (r.hasNext()) scan(r, depth + 1);
        r.endArray();
        break;
      case STRING:
        unicode(r.nextString());
        break;
      case NUMBER:
        String n = r.nextString();
        check(n.matches("0|[1-9][0-9]*") && Long.parseLong(n) <= MAX_INTEGER);
        break;
      case BOOLEAN:
        r.nextBoolean();
        break;
      case NULL:
        r.nextNull();
        break;
      default:
        throw new IllegalArgumentException("invalid_json");
    }
  }

  static String aad(String kind, String vault, String id) {
    return "keybridge/v1/" + kind + "/" + vault + "/" + id;
  }

  static byte[] hmac(byte[] key, byte[] data) throws Exception {
    Mac m = Mac.getInstance("HmacSHA256");
    m.init(new SecretKeySpec(key, "HmacSHA256"));
    return m.doFinal(data);
  }

  static byte[] derive(byte[] root, String vault, String device, String direction)
      throws Exception {
    byte[] prk = hmac(bytes("keybridge/v1/" + vault + "/" + device), root);
    byte[] info = bytes("keybridge/v1/" + direction);
    byte[] input = Arrays.copyOf(info, info.length + 1);
    input[input.length - 1] = 1;
    return hmac(prk, input);
  }

  static JSONObject seal(JSONObject plain, byte[] key, String aad) throws Exception {
    return seal(plain, key, aad, random(12));
  }

  static JSONObject seal(JSONObject plain, byte[] key, String aad, byte[] nonce) throws Exception {
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
    c.updateAAD(bytes(aad));
    byte[] out = c.doFinal(bytes(plain.toString()));
    return obj(
        "nonce",
        b64(nonce),
        "ciphertext",
        b64(Arrays.copyOf(out, out.length - 16)),
        "tag",
        b64(Arrays.copyOfRange(out, out.length - 16, out.length)));
  }

  static JSONObject unseal(JSONObject box, byte[] key, String aad) throws Exception {
    byte[] encrypted = binary(text(box, "ciphertext"), -1), tag = binary(text(box, "tag"), 16);
    byte[] all = Arrays.copyOf(encrypted, encrypted.length + 16);
    System.arraycopy(tag, 0, all, encrypted.length, 16);
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(
        Cipher.DECRYPT_MODE,
        new SecretKeySpec(key, "AES"),
        new GCMParameterSpec(128, binary(text(box, "nonce"), 12)));
    c.updateAAD(bytes(aad));
    return parse(c.doFinal(all), MAX_WIRE);
  }

  static boolean privateIp(InetAddress address, boolean test) {
    byte[] b = address.getAddress();
    int a = b[0] & 255, z = b[1] & 255;
    if (address.isLoopbackAddress()) return test;
    return b.length == 4
        ? (a == 10
            || a == 172 && z >= 16 && z <= 31
            || a == 192 && z == 168
            || a == 100 && z >= 64 && z <= 127)
        : (a & 254) == 252;
  }

  static URI endpoint(String raw, boolean test) throws Exception {
    URI u = new URI(raw);
    String host = u.getHost();
    check(host != null && host.matches("[0-9a-fA-F:.\\[\\]]+"));
    check(
        "https".equals(u.getScheme())
            && u.getUserInfo() == null
            && u.getQuery() == null
            && u.getFragment() == null
            && (u.getPath().isEmpty() || u.getPath().equals("/"))
            && u.getPort() > 0
            && u.getPort() <= 65535
            && privateIp(InetAddress.getByName(host), test));
    return u;
  }

  static JSONObject invitation(String value, boolean test) throws Exception {
    JSONObject q = parse(bytes(value), 16384);
    long t = System.currentTimeMillis() / 1000;
    check(
        number(q, "version") == 1
            && id(text(q, "vaultId"))
            && id(text(q, "pairId"))
            && number(q, "expiresAt") > t
            && number(q, "expiresAt") <= t + 330
            && text(q, "desktopName").length() <= 80);
    endpoint(text(q, "url"), test);
    binary(text(q, "secret"), 32);
    binary(text(q, "publicKey"), 32);
    binary(text(q, "certificateSha256"), 32);
    return q;
  }

  static void validateSnapshot(JSONObject s) throws Exception {
    check(number(s, "version") == 1 && id(text(s, "vaultId")) && number(s, "generation") > 0);
    number(s, "createdAt");
    check(Arrays.asList("linux", "macos").contains(text(s, "source")));
    JSONArray rows = s.getJSONArray("records");
    check(rows.length() <= 10000);
    Set<String> ids = new HashSet<>();
    for (int i = 0; i < rows.length(); i++) {
      JSONObject r = rows.getJSONObject(i);
      check(id(text(r, "id")) && ids.add(text(r, "id")) && bytes(r.toString()).length <= 65536);
      for (String k : new String[] {"title", "username", "password", "notes"}) text(r, k);
      check(Arrays.asList("active", "missing", "conflict").contains(text(r, "state")));
      JSONArray urls = r.getJSONArray("urls");
      check(urls.length() <= 100);
      for (int z = 0; z < urls.length(); z++)
        check(urls.get(z) instanceof String && urls.getString(z).length() <= 8192);
    }
  }

  static JSONObject verify(
      JSONObject signed, JSONObject pair, String request, long generation, String oldDigest)
      throws Exception {
    String payload = text(signed, "payload");
    byte[] body = binary(payload, -1);
    Ed25519Signer verifier = new Ed25519Signer();
    verifier.init(false, new Ed25519PublicKeyParameters(binary(text(pair, "publicKey"), 32), 0));
    byte[] input = bytes("keybridge.snapshot.v1\n" + payload);
    verifier.update(input, 0, input.length);
    check(verifier.verifySignature(binary(text(signed, "signature"), 64)));
    JSONObject p = parse(body, MAX_WIRE);
    check(request.equals(text(p, "requestId")));
    byte[] raw = binary(text(p, "snapshotBodyBase64"), -1);
    JSONObject s = parse(raw, MAX_BODY);
    validateSnapshot(s);
    String digest = b64(hash(raw));
    check(
        digest.equals(text(p, "snapshotSha256"))
            && text(pair, "vaultId").equals(text(s, "vaultId")));
    long g = number(s, "generation");
    check(g >= generation && (g != generation || digest.equals(oldDigest)));
    return obj("snapshot", s, "digest", digest);
  }
}
