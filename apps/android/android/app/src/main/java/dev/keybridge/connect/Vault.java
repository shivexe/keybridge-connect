package dev.keybridge.connect;

import android.app.KeyguardManager;
import android.content.*;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.*;
import android.security.keystore.*;
import java.security.KeyStore;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import org.json.*;

public final class Vault {
  private static Vault singleton;

  static synchronized Vault get(Context c) {
    if (singleton == null) singleton = new Vault(c.getApplicationContext());
    return singleton;
  }

  final Context context;
  private final SQLiteDatabase db;
  private JSONObject state;
  private long expires;
  private final String alias = "dev.keybridge.connect.vault.v1";
  private boolean failCommit;

  private Vault(Context c) {
    context = c;
    db = c.openOrCreateDatabase("vault.db", 0, null);
    try (Cursor mode = db.rawQuery("PRAGMA journal_mode=DELETE", null)) {
      if (!mode.moveToFirst() || !"delete".equalsIgnoreCase(mode.getString(0)))
        throw new IllegalStateException("journal_mode");
    }
    db.execSQL("PRAGMA synchronous=FULL");
    db.execSQL(
        "CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), ciphertext BLOB NOT"
            + " NULL)");
    c.registerReceiver(
        new BroadcastReceiver() {
          public void onReceive(Context c, Intent i) {
            lock();
          }
        },
        new IntentFilter(Intent.ACTION_SCREEN_OFF));
  }

  private SecretKey key(boolean create) throws Exception {
    KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
    ks.load(null);
    if (ks.containsAlias(alias)) return (SecretKey) ks.getKey(alias, null);
    Protocol.check(create && !hasData());
    KeyguardManager km = context.getSystemService(KeyguardManager.class);
    Protocol.check(km.isDeviceSecure());
    KeyGenerator generator = KeyGenerator.getInstance("AES", "AndroidKeyStore");
    KeyGenParameterSpec.Builder b =
        new KeyGenParameterSpec.Builder(
                alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true);
    if (Build.VERSION.SDK_INT >= 30)
      b.setUserAuthenticationParameters(
          300, KeyProperties.AUTH_DEVICE_CREDENTIAL | KeyProperties.AUTH_BIOMETRIC_STRONG);
    else b.setUserAuthenticationValidityDurationSeconds(300);
    generator.init(b.build());
    return generator.generateKey();
  }

  synchronized boolean hasData() {
    try (Cursor c = db.rawQuery("SELECT 1 FROM state WHERE id=1", null)) {
      return c.moveToFirst();
    }
  }

  synchronized void prepareKey() throws Exception {
    key(true);
  }

  synchronized void unlock() throws Exception {
    SecretKey k = key(true);
    try (Cursor c = db.rawQuery("SELECT ciphertext FROM state WHERE id=1", null)) {
      if (c.moveToFirst()) {
        byte[] sealed = c.getBlob(0);
        Protocol.check(sealed.length >= 28 && sealed.length <= 64 * 1024 * 1024);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, k, new GCMParameterSpec(128, Arrays.copyOf(sealed, 12)));
        cipher.updateAAD(Protocol.bytes("keybridge/v1/android-state"));
        state =
            Protocol.parse(
                cipher.doFinal(Arrays.copyOfRange(sealed, 12, sealed.length)), Protocol.MAX_WIRE);
      } else state = Protocol.obj("version", 1, "associations", new JSONArray());
    }
    expires = SystemClock.elapsedRealtime() + 300000;
  }

  synchronized void lock() {
    state = null;
    expires = 0;
  }

  synchronized boolean unlocked() {
    if (state != null
        && (SystemClock.elapsedRealtime() >= expires
            || context.getSystemService(KeyguardManager.class).isKeyguardLocked())) lock();
    return state != null;
  }

  synchronized JSONObject read() throws Exception {
    Protocol.check(unlocked());
    return Protocol.copy(state);
  }

  synchronized void commit(JSONObject next) throws Exception {
    Protocol.check(unlocked() && next.optLong("epoch", 0) == state.optLong("epoch", 0));
    next.put("epoch", state.optLong("epoch", 0) + 1);
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(Cipher.ENCRYPT_MODE, key(false));
    c.updateAAD(Protocol.bytes("keybridge/v1/android-state"));
    byte[] encrypted = c.doFinal(Protocol.bytes(next.toString()));
    byte[] sealed = Arrays.copyOf(c.getIV(), 12 + encrypted.length);
    System.arraycopy(encrypted, 0, sealed, 12, encrypted.length);
    db.beginTransaction();
    try {
      if (failCommit) throw new IllegalStateException("injected_commit_failure");
      ContentValues values = new ContentValues();
      values.put("id", 1);
      values.put("ciphertext", sealed);
      if (db.insertWithOnConflict("state", null, values, SQLiteDatabase.CONFLICT_REPLACE) < 0)
        throw new IllegalStateException("commit_failed");
      db.setTransactionSuccessful();
    } finally {
      db.endTransaction();
    }
    state = Protocol.copy(next);
  }

  boolean authenticateEveryTime() {
    return context
        .getSharedPreferences("security", Context.MODE_PRIVATE)
        .getBoolean("authenticateEveryTime", false);
  }

  void setAuthenticateEveryTime(boolean enabled) {
    Protocol.check(
        context
            .getSharedPreferences("security", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("authenticateEveryTime", enabled)
            .commit());
  }

  synchronized JSONObject publicStatus() throws Exception {
    JSONObject result =
        Protocol.obj(
            "unlocked",
            unlocked(),
            "hasVault",
            hasData(),
            "deviceSecure",
            context.getSystemService(KeyguardManager.class).isDeviceSecure());
    android.view.autofill.AutofillManager autofill =
        context.getSystemService(android.view.autofill.AutofillManager.class);
    result.put("authenticateEveryTime", authenticateEveryTime());
    result.put("credentialProviderSupported", Build.VERSION.SDK_INT >= 34);
    result.put("autofillEnabled", autofill != null && autofill.hasEnabledAutofillServices());
    if (unlocked()) {
      JSONObject active = state.optJSONObject("active");
      JSONObject snapshot = active == null ? null : active.optJSONObject("snapshot");
      result.put("paired", active != null);
      result.put("staged", state.has("staged"));
      result.put("generation", snapshot == null ? 0 : snapshot.getLong("generation"));
      result.put("count", snapshot == null ? 0 : snapshot.getJSONArray("records").length());
      result.put(
          "pendingReceipt", active != null && active.has("pendingReceipt") || state.has("staged"));
      result.put("lastConfirmed", active == null ? 0 : active.optLong("confirmedAt"));
      KeyInfo info =
          (KeyInfo)
              SecretKeyFactory.getInstance("AES", "AndroidKeyStore")
                  .getKeySpec(key(false), KeyInfo.class);
      result.put(
          "keyProtection", info.isInsideSecureHardware() ? "hardware-backed" : "software-backed");
    }
    return result;
  }

  synchronized JSONArray records() throws Exception {
    JSONObject a = read().optJSONObject("active");
    return a == null || !a.has("snapshot")
        ? new JSONArray()
        : a.getJSONObject("snapshot").getJSONArray("records");
  }

  synchronized JSONArray metadata(String query, int offset) throws Exception {
    Protocol.check(offset >= 0);
    JSONArray rows = records(), out = new JSONArray();
    int matched = 0;
    for (int i = 0; i < rows.length() && out.length() < 100; i++) {
      JSONObject r = rows.getJSONObject(i);
      if (!(r.getString("title") + " " + r.getString("username"))
          .toLowerCase(Locale.ROOT)
          .contains(query.toLowerCase(Locale.ROOT))) continue;
      if (matched++ < offset) continue;
      out.put(
          Protocol.obj(
              "id",
              r.getString("id"),
              "title",
              r.getString("title"),
              "username",
              r.getString("username"),
              "state",
              r.getString("state"),
              "urls",
              r.getJSONArray("urls")));
    }
    return out;
  }

  synchronized JSONObject record(String id) throws Exception {
    JSONArray rows = records();
    for (int i = 0; i < rows.length(); i++)
      if (rows.getJSONObject(i).getString("id").equals(id)) return rows.getJSONObject(i);
    throw new IllegalArgumentException("record_missing");
  }

  synchronized void unpair() throws Exception {
    Protocol.check(unlocked());
    db.beginTransaction();
    try {
      db.delete("state", "id=1", null);
      db.setTransactionSuccessful();
    } finally {
      db.endTransaction();
    }
    KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
    ks.load(null);
    ks.deleteEntry(alias);
    lock();
  }

  synchronized void setFailCommit(boolean fail) {
    Protocol.check(BuildConfig.DEBUG);
    failCommit = fail;
  }
}
