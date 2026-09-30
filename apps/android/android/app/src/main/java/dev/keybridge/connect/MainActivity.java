package dev.keybridge.connect;

import android.content.*;
import android.os.*;
import android.provider.Settings;
import android.view.WindowManager;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.concurrent.*;
import org.json.*;

public final class MainActivity extends FlutterFragmentActivity {
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final ExecutorService reader = Executors.newSingleThreadExecutor();
  private Vault vault;
  private SyncEngine sync;
  private MethodChannel.Result unlockResult;
  private ActionAuthentication authentication;

  @Override
  protected void attachBaseContext(android.content.Context base) {
    super.attachBaseContext(AccountSheet.darkContext(base));
  }

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    authentication = new ActionAuthentication(this);
  }

  @Override
  protected void onDestroy() {
    if (authentication != null) authentication.cancel();
    worker.shutdown();
    reader.shutdown();
    super.onDestroy();
  }

  @Override
  public void configureFlutterEngine(FlutterEngine engine) {
    super.configureFlutterEngine(engine);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    vault = Vault.get(this);
    sync = new SyncEngine(vault, false);
    new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.keybridge.connect/native")
        .setMethodCallHandler(
            (call, result) -> {
              if (call.method.equals("unlock")) {
                unlockResult = result;
                startActivityForResult(new Intent(this, UnlockActivity.class), 60);
                return;
              }
              if (call.method.equals("settings")) {
                String type = call.argument("type");
                Intent i;
                if ("camera".equals(type))
                  i =
                      new Intent(
                          Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                          android.net.Uri.parse("package:" + getPackageName()));
                else if ("autofill".equals(type))
                  i =
                      new Intent(
                          Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE,
                          android.net.Uri.parse("package:" + getPackageName()));
                else if ("accessibility".equals(type))
                  i = new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS);
                else if ("credential".equals(type) && Build.VERSION.SDK_INT >= 34)
                  i =
                      new Intent(
                          "android.settings.CREDENTIAL_PROVIDER",
                          android.net.Uri.parse("package:" + getPackageName()));
                else i = new Intent(Settings.ACTION_SECURITY_SETTINGS);
                try {
                  startActivity(i);
                  result.success(null);
                } catch (Exception e) {
                  result.error("settings_unavailable", "Open Android Settings manually", null);
                }
                return;
              }
              boolean protectedAction = sensitiveAction(call.method);
              boolean policyChange = call.method.equals("setAuthenticateEveryTime");
              if (policyChange || protectedAction && vault.authenticateEveryTime()) {
                String title =
                    policyChange
                        ? "Change authentication setting"
                        : switch (call.method) {
                          case "copy" -> "Copy password";
                          case "reveal" -> "Show password";
                          case "beginPair" -> "Pair a computer";
                          case "unpair" -> "Disconnect computer";
                          case "clearAssociations" -> "Forget app approvals";
                          default -> "Select account";
                        };
                authentication.request(
                    title,
                    () -> execute(call, result, true),
                    message ->
                        result.error(
                            message.startsWith("Authentication cancelled")
                                ? "authentication_cancelled"
                                : "authentication_failed",
                            message,
                            null));
              } else execute(call, result, false);
            });
  }

  static boolean sensitiveAction(String method) {
    return java.util.Set.of(
            "reveal", "copy", "authorizeSelection", "beginPair", "unpair", "clearAssociations")
        .contains(method);
  }

  private void execute(
      io.flutter.plugin.common.MethodCall call,
      MethodChannel.Result result,
      boolean authenticated) {
    (java.util.Set.of("status", "list", "lock", "reveal", "copy", "authorizeSelection")
                .contains(call.method)
            ? reader
            : worker)
        .execute(
            () -> {
              try {
                if (sensitiveAction(call.method) && vault.authenticateEveryTime())
                  Protocol.check(authenticated);
                if (authenticated) vault.unlock();
                Object value;
                switch (call.method) {
                  case "status":
                    value = vault.publicStatus().toString();
                    break;
                  case "lock":
                    vault.lock();
                    value = null;
                    break;
                  case "list":
                    value =
                        vault
                            .metadata(
                                call.argument("query"),
                                ((Number) call.argument("offset")).intValue())
                            .toString();
                    break;
                  case "setAuthenticateEveryTime":
                    Protocol.check(authenticated);
                    vault.setAuthenticateEveryTime(Boolean.TRUE.equals(call.argument("enabled")));
                    value = null;
                    break;
                  case "authorizeSelection":
                    Protocol.check(vault.unlocked());
                    value = null;
                    break;
                  case "reveal":
                    value = vault.record(call.argument("id")).getString("password");
                    break;
                  case "copy":
                    copy(vault.record(call.argument("id")).getString("password"));
                    value = null;
                    break;
                  case "beginPair":
                    value = sync.beginPair(call.argument("code")).toString();
                    break;
                  case "pollPair":
                    value = sync.pollPair().toString();
                    break;
                  case "cancelReplacement":
                    sync.cancelUncommittedReplacement();
                    value = null;
                    break;
                  case "cancelPair":
                    sync.cancelPair();
                    value = null;
                    break;
                  case "sync":
                    value = sync.sync().toString();
                    break;
                  case "unpair":
                    sync.cancelPair();
                    vault.unpair();
                    value = null;
                    break;
                  case "associations":
                    value = vault.read().getJSONArray("associations").toString();
                    break;
                  case "clearAssociations":
                    JSONObject next = vault.read();
                    next.put("associations", new JSONArray());
                    next.remove("verifiedOrigins");
                    vault.commit(next);
                    value = null;
                    break;
                  default:
                    runOnUiThread(result::notImplemented);
                    return;
                }
                Object answer = value;
                runOnUiThread(() -> result.success(answer));
              } catch (Exception e) {
                runOnUiThread(
                    () ->
                        result.error(
                            "operation_failed",
                            "Operation failed. Your previous vault is preserved. Check"
                                + " unlock, pairing, and desktop availability.",
                            null));
              }
            });
  }

  private void copy(String password) {
    runOnUiThread(
        () -> {
          ClipboardManager clipboard = getSystemService(ClipboardManager.class);
          String label = "Keybridge " + java.util.UUID.randomUUID();
          ClipData clip = ClipData.newPlainText(label, password);
          PersistableBundle extra = new PersistableBundle();
          extra.putBoolean("android.content.extra.IS_SENSITIVE", true);
          clip.getDescription().setExtras(extra);
          clipboard.setPrimaryClip(clip);
          new Handler(Looper.getMainLooper())
              .postDelayed(
                  () -> {
                    ClipData current = clipboard.getPrimaryClip();
                    if (current != null
                        && label.contentEquals(current.getDescription().getLabel())
                        && current.getItemCount() == 1
                        && current.getItemAt(0).getText() != null
                        && password.contentEquals(current.getItemAt(0).getText())) {
                      if (Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip();
                      else clipboard.setPrimaryClip(ClipData.newPlainText("", ""));
                    }
                  },
                  30000);
        });
  }

  @Override
  protected void onActivityResult(int req, int res, Intent data) {
    super.onActivityResult(req, res, data);
    if (req == 60 && unlockResult != null) {
      if (res == RESULT_OK) unlockResult.success(null);
      else unlockResult.error("authentication_cancelled", "Authentication cancelled", null);
      unlockResult = null;
    }
  }

  @Override
  protected void onStop() {
    super.onStop();
    if (vault != null) vault.lock();
  }
}
