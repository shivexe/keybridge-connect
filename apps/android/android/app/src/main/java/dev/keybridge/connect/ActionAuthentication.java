package dev.keybridge.connect;

import android.os.Build;
import androidx.biometric.BiometricManager;
import androidx.biometric.BiometricPrompt;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.FragmentActivity;

final class ActionAuthentication {
  private final FragmentActivity activity;
  private final BiometricPrompt prompt;
  private Runnable pending;
  private long requestVersion;
  private java.util.function.Consumer<String> failure;

  ActionAuthentication(FragmentActivity activity) {
    this.activity = activity;
    prompt =
        new BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            new BiometricPrompt.AuthenticationCallback() {
              @Override
              public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
                completeWhenFocused(100, requestVersion);
              }

              @Override
              public void onAuthenticationError(int code, CharSequence message) {
                java.util.function.Consumer<String> callback = failure;
                pending = null;
                failure = null;
                if (callback != null)
                  callback.accept(
                      code == BiometricPrompt.ERROR_USER_CANCELED
                              || code == BiometricPrompt.ERROR_CANCELED
                              || code == BiometricPrompt.ERROR_NEGATIVE_BUTTON
                          ? "Authentication cancelled. Nothing was shared."
                          : message.toString());
              }
            });
  }

  private void completeWhenFocused(int attempts, long version) {
    if (pending == null || version != requestVersion) return;
    if (activity.isFinishing() || activity.isDestroyed()) {
      cancel();
      return;
    }
    if (activity.hasWindowFocus()) {
      Runnable action = pending;
      pending = null;
      failure = null;
      action.run();
    } else if (attempts > 0) {
      new android.os.Handler(android.os.Looper.getMainLooper())
          .postDelayed(() -> completeWhenFocused(attempts - 1, version), 50);
    } else {
      java.util.function.Consumer<String> callback = failure;
      pending = null;
      failure = null;
      if (callback != null)
        callback.accept("Authentication cancelled. Return to Keybridge and try again.");
    }
  }

  static int authenticators() {
    return Build.VERSION.SDK_INT >= 30
        ? BiometricManager.Authenticators.BIOMETRIC_STRONG
            | BiometricManager.Authenticators.DEVICE_CREDENTIAL
        : BiometricManager.Authenticators.BIOMETRIC_STRONG;
  }

  void request(String title, Runnable action, java.util.function.Consumer<String> error) {
    if (pending != null) {
      error.accept("Finish the current authentication first.");
      return;
    }
    if (BiometricManager.from(activity).canAuthenticate(authenticators())
        != BiometricManager.BIOMETRIC_SUCCESS) {
      error.accept(
          Build.VERSION.SDK_INT >= 30
              ? "Set up a fingerprint or screen lock in Android settings."
              : "Set up a fingerprint in Android settings to use authentication for every action.");
      return;
    }
    requestVersion++;
    pending = action;
    failure = error;
    BiometricPrompt.PromptInfo.Builder info =
        new BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle("Confirm it’s you to continue in Keybridge")
            .setAllowedAuthenticators(authenticators())
            .setConfirmationRequired(true);
    if (Build.VERSION.SDK_INT < 30) info.setNegativeButtonText("Cancel");
    try {
      prompt.authenticate(info.build());
    } catch (Exception e) {
      pending = null;
      failure = null;
      error.accept("Authentication unavailable. Try again from Keybridge.");
    }
  }

  void cancel() {
    if (pending == null) return;
    pending = null;
    failure = null;
    prompt.cancelAuthentication();
  }
}
