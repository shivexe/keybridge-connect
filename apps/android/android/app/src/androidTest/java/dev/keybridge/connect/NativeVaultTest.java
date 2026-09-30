package dev.keybridge.connect;

import static org.junit.Assert.*;

import android.content.*;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.*;
import java.nio.file.*;
import org.json.*;
import org.junit.*;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class NativeVaultTest {
  Context context;
  Vault vault;

  @Before
  public void setup() {
    context = InstrumentationRegistry.getInstrumentation().getTargetContext();
    vault = Vault.get(context);
  }

  void authenticate() throws Exception {
    android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    UiDevice.getInstance(instrumentation)
        .executeShellCommand("am start -n dev.keybridge.connect/.MainActivity");
    Thread.sleep(1500);
    vault.lock();
    instrumentation.runOnMainSync(
        () -> {
          android.app.Activity main =
              androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                  .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED)
                  .iterator()
                  .next();
          main.startActivity(new Intent(main, UnlockActivity.class));
        });
    UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
    long promptDeadline = System.currentTimeMillis() + 10000;
    UiObject title = device.findObject(new UiSelector().text("Unlock Keybridge Connect"));
    while (!vault.unlocked() && !title.exists() && System.currentTimeMillis() < promptDeadline)
      Thread.sleep(100);
    if (vault.unlocked()) return;
    assertTrue("OS credential title", title.exists());
    UiObject input = device.findObject(new UiSelector().className("android.widget.EditText"));
    assertTrue("Device credential prompt", input.waitForExists(10000));
    input.click();
    device.executeShellCommand("input text 123456");
    device.pressEnter();
    long end = System.currentTimeMillis() + 10000;
    while (!vault.unlocked() && System.currentTimeMillis() < end) Thread.sleep(100);
    assertTrue("Keystore unlocked by normal OS confirmation", vault.unlocked());
  }

  byte[] readAsset(String name) throws Exception {
    try (java.io.InputStream in =
            InstrumentationRegistry.getInstrumentation().getContext().getAssets().open(name);
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream()) {
      byte[] b = new byte[4096];
      int n;
      while ((n = in.read(b)) != -1) out.write(b, 0, n);
      return out.toByteArray();
    }
  }

  @Test
  public void vectorsAndStrictBoundaries() throws Exception {
    JSONObject v = Protocol.parse(readAsset("protocol-vectors.json"), Protocol.MAX_WIRE);
    assertEquals(
        v.getString("c2s"),
        Protocol.b64(
            Protocol.derive(
                Protocol.binary(v.getString("root"), 32),
                v.getString("vaultId"),
                v.getString("deviceId"),
                "c2s")));
    assertEquals(
        v.getJSONObject("plaintext").toString(),
        Protocol.unseal(
                v.getJSONObject("envelope"),
                Protocol.binary(v.getString("c2s"), 32),
                v.getString("aad"))
            .toString());
    JSONObject verified =
        Protocol.verify(
            v.getJSONObject("signed"),
            Protocol.obj("vaultId", v.getString("vaultId"), "publicKey", v.getString("publicKey")),
            v.getJSONObject("plaintext").getString("requestId"),
            0,
            "");
    assertEquals(v.getString("digest"), verified.getString("digest"));
    for (String invalid :
        new String[] {"{\"a\":1,\"a\":2}", "{\"a\":-1}", "{\"a\":1.0}", "{\"a\":\"\\ud800\"}"}) {
      try {
        Protocol.parse(Protocol.bytes(invalid), 1000);
        fail("Accepted malformed JSON");
      } catch (IllegalArgumentException | java.io.IOException expected) {
      }
    }
    assertFalse(
        Matcher.host("https://bank.example.attacker.test")
            .equals(Matcher.host("https://bank.example")));
    try {
      Protocol.verify(
          v.getJSONObject("signed"),
          Protocol.obj("vaultId", v.getString("vaultId"), "publicKey", v.getString("publicKey")),
          v.getJSONObject("plaintext").getString("requestId"),
          2,
          "");
      fail("rollback");
    } catch (IllegalArgumentException expected) {
    }
  }

  @Test
  public void realPairCommitReceiptAndOfflineRestart() throws Exception {
    authenticate();
    vault.unpair();
    authenticate();
    String path = InstrumentationRegistry.getArguments().getString("invitation");
    assertNotNull(path);
    String code =
        new String(Files.readAllBytes(Paths.get(path)), java.nio.charset.StandardCharsets.UTF_8);
    SyncEngine engine = new SyncEngine(vault, true);
    assertEquals(6, engine.beginPair(code).getString("comparison").length());
    JSONObject pair = null;
    for (int i = 0; i < 120; i++) {
      pair = engine.pollPair();
      if (pair.getString("status").equals("pending")) {
        android.os.Bundle progress = new android.os.Bundle();
        progress.putString("pairing", "awaiting_desktop_approval");
        InstrumentationRegistry.getInstrumentation().sendStatus(2, progress);
      }
      if (pair.getString("status").equals("approved")) break;
      Thread.sleep(2000);
    }
    assertEquals("approved", pair.getString("status"));
    vault.setFailCommit(true);
    try {
      engine.sync();
      fail("failed commit accepted");
    } catch (Exception expected) {
    } finally {
      vault.setFailCommit(false);
    }
    assertFalse(vault.read().getJSONObject("staged").has("pendingReceipt"));
    engine.dropAckConfirmationForTest = true;
    try {
      engine.sync();
      fail("lost receipt response accepted");
    } catch (java.io.IOException expected) {
    }
    assertTrue(vault.read().getJSONObject("staged").has("pendingReceipt"));
    vault.lock();
    authenticate();
    assertTrue(vault.read().getJSONObject("staged").has("pendingReceipt"));
    assertEquals("synced", engine.sync().getString("status"));
    assertEquals(
        Integer.parseInt(InstrumentationRegistry.getArguments().getString("count", "3")),
        vault.records().length());
    assertFalse(vault.read().has("staged"));
    assertFalse(vault.read().getJSONObject("active").has("pendingReceipt"));
    String password = vault.records().getJSONObject(0).getString("password");
    vault.lock();
    try {
      vault.records();
      fail("locked read");
    } catch (IllegalArgumentException expected) {
    }
    authenticate();
    assertEquals(password, vault.records().getJSONObject(0).getString("password"));
    String bytes =
        new String(
            Files.readAllBytes(context.getDatabasePath("vault.db").toPath()),
            java.nio.charset.StandardCharsets.ISO_8859_1);
    assertFalse(bytes.contains("KB_SYNTHETIC_CANARY"));
    assertFalse(bytes.contains("dummy0"));
    assertEquals("synced", engine.sync().getString("status"));
  }
}
