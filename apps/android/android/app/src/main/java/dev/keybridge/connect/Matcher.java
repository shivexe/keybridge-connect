package dev.keybridge.connect;

import android.content.Context;
import android.content.pm.*;
import android.os.Build;
import java.net.*;
import java.util.*;
import org.json.*;

final class Matcher {
  static String fingerprint(Context c, String pkg) throws Exception {
    PackageInfo info =
        c.getPackageManager()
            .getPackageInfo(
                pkg,
                Build.VERSION.SDK_INT >= 28
                    ? PackageManager.GET_SIGNING_CERTIFICATES
                    : PackageManager.GET_SIGNATURES);
    Signature[] signatures =
        Build.VERSION.SDK_INT >= 28 ? info.signingInfo.getApkContentsSigners() : info.signatures;
    Protocol.check(signatures != null && signatures.length > 0);
    List<String> values = new ArrayList<>();
    for (Signature s : signatures) values.add(Protocol.b64(Protocol.hash(s.toByteArray())));
    Collections.sort(values);
    return String.join(",", values);
  }

  static String host(String raw) {
    try {
      URI u = new URI(raw);
      if (!"https".equals(u.getScheme())
          || u.getRawUserInfo() != null
          || u.getRawAuthority() == null) return "";
      String rawHost = u.getHost();
      if (rawHost == null) {
        rawHost = u.getRawAuthority();
        if (rawHost.contains("@") || rawHost.contains("%") || rawHost.contains(":")) return "";
      }
      String h = IDN.toASCII(rawHost, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
      return h.endsWith(".") ? h.substring(0, h.length() - 1) : h;
    } catch (Exception e) {
      return "";
    }
  }

  static boolean matchesOrigin(JSONObject row, String origin) throws Exception {
    String h = host(origin);
    if (h.isEmpty()) return false;
    JSONArray urls = row.getJSONArray("urls");
    for (int i = 0; i < urls.length(); i++) if (h.equals(host(urls.getString(i)))) return true;
    return false;
  }

  static boolean associated(Vault vault, String pkg, String signature, String origin, String id)
      throws Exception {
    JSONObject state = vault.read();
    JSONArray verified = state.optJSONArray("verifiedOrigins");
    if (verified != null && !origin.isEmpty())
      for (int i = 0; i < verified.length(); i++) {
        JSONObject b = verified.getJSONObject(i);
        if (pkg.equals(b.getString("package"))
            && signature.equals(b.getString("signature"))
            && host(origin).equals(b.getString("host"))
            && b.getLong("expiresAt") > System.currentTimeMillis() / 1000
            && matchesOrigin(vault.record(id), origin)) return true;
      }
    JSONArray bindings = state.optJSONArray("associations");
    if (bindings == null) return false;
    for (int i = 0; i < bindings.length(); i++) {
      JSONObject b = bindings.getJSONObject(i);
      if (pkg.equals(b.getString("package"))
          && signature.equals(b.getString("signature"))
          && origin.equals(b.getString("origin"))
          && id.equals(b.getString("recordId"))) return true;
    }
    return false;
  }

  static void associate(Vault vault, String pkg, String signature, String origin, String id)
      throws Exception {
    Protocol.check(signature.equals(fingerprint(vault.context, pkg)));
    JSONObject next = vault.read();
    JSONArray a = next.getJSONArray("associations");
    if (!associated(vault, pkg, signature, origin, id))
      a.put(Protocol.obj("package", pkg, "signature", signature, "origin", origin, "recordId", id));
    next.put("associations", a);
    vault.commit(next);
  }
}
