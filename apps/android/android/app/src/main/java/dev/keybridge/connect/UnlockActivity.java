package dev.keybridge.connect;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.WindowManager;
import android.widget.*;

public class UnlockActivity extends androidx.fragment.app.FragmentActivity {
  protected Vault vault;
  protected AccountSheet sheet;
  private ActionAuthentication authentication;

  @Override
  protected void attachBaseContext(android.content.Context base) {
    super.attachBaseContext(AccountSheet.darkContext(base));
  }

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    authentication = new ActionAuthentication(this);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    sheet = new AccountSheet(this);
    vault = Vault.get(this);
    if (vault.unlocked()) onUnlocked();
    else authenticate();
  }

  void authenticate() {
    sheet.message(
        "Unlock your passwords",
        "Confirm your screen lock to choose a saved account.",
        "Cancel",
        this::finish);
    KeyguardManager km = getSystemService(KeyguardManager.class);
    if (!km.isDeviceSecure()) {
      message("Set a device screen lock in Android Settings before using the vault.");
      return;
    }
    try {
      vault.prepareKey();
      Intent prompt =
          km.createConfirmDeviceCredentialIntent(
              "Unlock Keybridge Connect", "Authorize access to your offline passwords");
      if (prompt == null) {
        message("Device authentication unavailable.");
        return;
      }
      startActivityForResult(prompt, 50);
    } catch (Exception e) {
      message(
          "Vault key unavailable. Preserve the app data and restore access or re-pair after an"
              + " explicit reset.");
    }
  }

  @Override
  protected void onActivityResult(int request, int result, Intent data) {
    super.onActivityResult(request, result, data);
    if (request == 50) {
      if (result != RESULT_OK) {
        setResult(RESULT_CANCELED);
        finish();
        return;
      }
      try {
        vault.unlock();
        onUnlocked();
      } catch (Exception e) {
        vault.lock();
        message("Unlock failed. Your encrypted vault has been preserved.");
      }
    }
  }

  protected void authorizePassword(Runnable action) {
    if (!vault.authenticateEveryTime()) {
      action.run();
      return;
    }
    authentication.request(
        "Use this password",
        () -> {
          try {
            vault.unlock();
            action.run();
          } catch (Exception e) {
            message("Unlock failed. Your saved passwords are unchanged.");
          }
        },
        explanation -> {
          sheet.message("Password not shared", explanation, "Back to accounts", this::onUnlocked);
        });
  }

  @Override
  protected void onDestroy() {
    authentication.cancel();
    super.onDestroy();
  }

  protected void onUnlocked() {
    setResult(RESULT_OK);
    finish();
  }

  protected void message(String text) {
    sheet.message("Couldn’t fill this time", text, "Close", this::finish);
  }
}
