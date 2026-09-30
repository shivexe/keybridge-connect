package dev.keybridge.connect;

import android.accessibilityservice.AccessibilityService;
import android.content.*;
import android.os.Bundle;
import android.view.accessibility.*;
import org.json.JSONObject;

public final class KeybridgeAccessibilityService extends AccessibilityService {
  private static KeybridgeAccessibilityService instance;

  @Override
  protected void onServiceConnected() {
    instance = this;
    getAccessibilityButtonController()
        .registerAccessibilityButtonCallback(
            new android.accessibilityservice.AccessibilityButtonController
                .AccessibilityButtonCallback() {
              @Override
              public void onClicked(android.accessibilityservice.AccessibilityButtonController c) {
                invoke();
              }
            });
  }

  @Override
  public void onDestroy() {
    instance = null;
    super.onDestroy();
  }

  @Override
  public void onAccessibilityEvent(AccessibilityEvent event) {}

  @Override
  public void onInterrupt() {}

  @Override
  protected boolean onGesture(int gestureId) {
    if (gestureId == GESTURE_SWIPE_UP_AND_RIGHT) {
      invoke();
      return true;
    }
    return false;
  }

  private void invoke() {
    try {
      AccessibilityNodeInfo root = getRootInActiveWindow();
      if (root == null) return;
      AccessibilityNodeInfo node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
      if (node == null || !node.isEditable() || node.getViewIdResourceName() == null) return;
      String kind = fieldKind(node);
      if (kind.isEmpty()) return;
      String pkg = node.getPackageName().toString();
      if (pkg.equals(getPackageName()) || pkg.startsWith("com.android.") || pkg.equals("android"))
        return;
      int type = node.getInputType();
      if ((type & 15) == 2) return;
      startActivity(
          new Intent(this, PickerActivity.class)
              .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
              .putExtra("accessibility", true)
              .putExtra("accessibilityKind", kind)
              .putExtra("package", pkg)
              .putExtra("signature", Matcher.fingerprint(this, pkg))
              .putExtra("origin", "")
              .putExtra("window", node.getWindowId())
              .putExtra("node", node.getViewIdResourceName()));
    } catch (Exception ignored) {
    }
  }

  static String fieldKind(AccessibilityNodeInfo node) {
    return fieldKind(node.isPassword(), node.getInputType(), node.getViewIdResourceName());
  }

  static String fieldKind(boolean password, int inputType, String id) {
    if ((inputType & 15) == 2) return "";
    if (password) return "password";
    if (id == null) return "";
    String name = id.substring(id.lastIndexOf('/') + 1).toLowerCase(java.util.Locale.ROOT);
    if (name.matches(".*(search|otp|code|pin|card).*")) return "";
    int variation = inputType & 0xff0;
    return variation == 0x20
            || variation == 0xd0
            || name.matches("(username|user_name|email|email_address|emailaddress|login-email)")
        ? "username"
        : "";
  }

  static boolean fill(
      Context context,
      String pkg,
      String signature,
      int window,
      String nodeId,
      String kind,
      JSONObject record)
      throws Exception {
    KeybridgeAccessibilityService service = instance;
    if (service == null || !signature.equals(Matcher.fingerprint(context, pkg))) return false;
    if (!kind.equals("password") && !kind.equals("username")) return false;
    String value = record.getString(kind);
    if (value.isEmpty()) return false;
    new android.os.Handler(android.os.Looper.getMainLooper())
        .postDelayed(
            () -> {
              try {
                if (!Vault.get(context).unlocked()
                    || !signature.equals(Matcher.fingerprint(context, pkg))) return;
                AccessibilityNodeInfo root = service.getRootInActiveWindow();
                if (root == null
                    || root.getWindowId() != window
                    || !pkg.contentEquals(root.getPackageName())) return;
                AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                if (focused == null
                    || !focused.isEditable()
                    || !kind.equals(fieldKind(focused))
                    || !nodeId.equals(focused.getViewIdResourceName())
                    || focused.getWindowId() != window) return;
                Bundle arguments = new Bundle();
                arguments.putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
                focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments);
              } catch (Exception ignored) {
              }
            },
            400);
    return true;
  }
}
