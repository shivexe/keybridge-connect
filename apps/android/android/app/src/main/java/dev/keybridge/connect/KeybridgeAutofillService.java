package dev.keybridge.connect;

import android.app.PendingIntent;
import android.app.assist.AssistStructure;
import android.content.Intent;
import android.os.*;
import android.service.autofill.*;
import android.view.autofill.AutofillId;
import android.widget.RemoteViews;
import androidx.autofill.inline.v1.InlineSuggestionUi;
import java.util.*;

public final class KeybridgeAutofillService extends AutofillService {
  static final class Field {
    final AutofillId id;
    final String kind, origin;
    final boolean secure, focused;
    final int window;
    final Object form;

    Field(
        AutofillId id,
        String kind,
        String origin,
        boolean secure,
        boolean focused,
        int window,
        Object form) {
      this.id = id;
      this.kind = kind;
      this.origin = origin;
      this.secure = secure;
      this.focused = focused;
      this.window = window;
      this.form = form;
    }
  }

  static final class Form {
    String pkg, origin = "", reason = "";
    ArrayList<AutofillId> ids = new ArrayList<>();
    ArrayList<String> kinds = new ArrayList<>();
    ArrayList<Field> fields = new ArrayList<>();
    int visited;
    boolean unsafe;
  }

  static Form inspect(AssistStructure structure) {
    Form f = new Form();
    f.pkg = structure.getActivityComponent().getPackageName();
    for (int i = 0; i < structure.getWindowNodeCount(); i++)
      visit(structure.getWindowNodeAt(i).getRootViewNode(), f, "", true, i, null);
    selectFocusedForm(f);
    return f;
  }

  static void selectFocusedForm(Form f) {
    Field focused = null;
    for (Field field : f.fields) {
      if (!field.focused) continue;
      if (focused != null) {
        f.unsafe = true;
        f.reason = "ambiguous_focus";
        return;
      }
      focused = field;
    }
    if (focused == null || focused.kind.isEmpty()) {
      f.reason = "no_focused_login";
      return;
    }
    if (!focused.secure) {
      f.unsafe = true;
      f.reason = "missing_secure_origin";
      return;
    }
    f.origin = focused.origin;
    for (Field field : f.fields) {
      if (field.secure
          && field.window == focused.window
          && field.form == focused.form
          && field.origin.equals(focused.origin)
          && !field.kind.isEmpty()) {
        f.ids.add(field.id);
        f.kinds.add(field.kind);
      }
    }
  }

  static void visit(
      AssistStructure.ViewNode node,
      Form f,
      String origin,
      boolean secure,
      int window,
      Object form) {
    if (++f.visited > 2000) {
      f.unsafe = true;
      f.reason = "page_too_large";
      return;
    }
    if (node.getVisibility() != android.view.View.VISIBLE) return;
    String domain = node.getWebDomain();
    if (domain != null && !domain.isEmpty()) {
      String host = Matcher.host("https://" + domain);
      origin = "https://" + host;
      secure =
          !host.isEmpty() && (Build.VERSION.SDK_INT < 28 || "https".equals(node.getWebScheme()));
    }
    if (node.getHtmlInfo() != null && "form".equalsIgnoreCase(node.getHtmlInfo().getTag()))
      form = node;
    if (node.getAutofillId() != null
        && node.isEnabled()
        && node.getAutofillType() == android.view.View.AUTOFILL_TYPE_TEXT) {
      String kind = fieldKind(node);
      if (!kind.isEmpty() || node.isFocused())
        f.fields.add(
            new Field(node.getAutofillId(), kind, origin, secure, node.isFocused(), window, form));
    }
    for (int i = 0; i < node.getChildCount() && !f.unsafe; i++)
      visit(node.getChildAt(i), f, origin, secure, window, form);
  }

  static String fieldKind(AssistStructure.ViewNode node) {
    if ((node.getInputType() & 15) == 2) return "";
    String kind = "";
    if (node.getHtmlInfo() != null && node.getHtmlInfo().getAttributes() != null) {
      for (android.util.Pair<String, String> attribute : node.getHtmlInfo().getAttributes()) {
        String name = attribute.first, value = attribute.second;
        if ("autocomplete".equals(name) && value.matches(".*(cc-|one-time-code|new-password).*"))
          return "";
        if (("type".equals(name) && "password".equals(value))
            || ("autocomplete".equals(name) && "current-password".equals(value))) kind = "password";
        else if (("type".equals(name) && "email".equals(value))
            || ("autocomplete".equals(name) && ("username".equals(value) || "email".equals(value))))
          kind = "username";
      }
    }
    String[] hints = node.getAutofillHints();
    if (hints != null)
      for (String h : hints) {
        if ("password".equals(h)) kind = "password";
        else if ("username".equals(h) || "emailAddress".equals(h)) kind = "username";
        else if (h.toLowerCase(Locale.ROOT).matches(".*(credit|pin|otp|sms|newpassword).*"))
          return "";
      }
    int variation = node.getInputType() & 0xff0;
    if (variation == 0x80 || variation == 0xe0 || variation == 0x90) kind = "password";
    if (kind.isEmpty() && (variation == 0x20 || variation == 0xd0)) kind = "username";
    return kind;
  }

  @Override
  public void onFillRequest(
      FillRequest request, CancellationSignal cancellation, FillCallback callback) {
    try {
      if (cancellation.isCanceled()) {
        callback.onSuccess(null);
        return;
      }
      List<FillContext> contexts = request.getFillContexts();
      Form f = inspect(contexts.get(contexts.size() - 1).getStructure());
      if (f.unsafe
          || f.ids.isEmpty()
          || f.ids.size() > 12
          || f.pkg.equals(getPackageName())
          || f.pkg.equals("com.android.systemui")
          || f.pkg.equals("com.android.settings")) {
        report(f.reason.isEmpty() ? "no_login_fields" : f.reason);
        callback.onSuccess(null);
        return;
      }
      String signature = Matcher.fingerprint(this, f.pkg);
      Intent intent =
          new Intent(this, PickerActivity.class)
              .setAction(java.util.UUID.randomUUID().toString())
              .putExtra("package", f.pkg)
              .putExtra("signature", signature)
              .putExtra("origin", f.origin)
              .putParcelableArrayListExtra("ids", f.ids)
              .putStringArrayListExtra("kinds", f.kinds);
      PendingIntent pending =
          PendingIntent.getActivity(
              this, 0, intent, PendingIntent.FLAG_CANCEL_CURRENT | PendingIntent.FLAG_MUTABLE);
      RemoteViews label = new RemoteViews(getPackageName(), android.R.layout.simple_list_item_1);
      label.setTextViewText(android.R.id.text1, "Unlock Keybridge · choose account");
      Dataset.Builder dataset =
          new Dataset.Builder(label).setAuthentication(pending.getIntentSender());
      for (AutofillId id : f.ids) dataset.setValue(id, null);
      if (Build.VERSION.SDK_INT >= 30
          && request.getInlineSuggestionsRequest() != null
          && !request.getInlineSuggestionsRequest().getInlinePresentationSpecs().isEmpty()) {
        android.app.slice.Slice slice =
            InlineSuggestionUi.newContentBuilder(pending)
                .setTitle("Keybridge")
                .setSubtitle("Choose login")
                .build()
                .getSlice();
        dataset.setInlinePresentation(
            new InlinePresentation(
                slice,
                request.getInlineSuggestionsRequest().getInlinePresentationSpecs().get(0),
                false));
      }
      callback.onSuccess(new FillResponse.Builder().addDataset(dataset.build()).build());
      report("suggestion_offered");
    } catch (Exception e) {
      report("suggestion_error_" + e.getClass().getSimpleName());
      callback.onSuccess(null);
    }
  }

  private void report(String outcome) {
    getSharedPreferences("autofill-status", MODE_PRIVATE)
        .edit()
        .putString("outcome", outcome)
        .putLong("time", System.currentTimeMillis())
        .apply();
    if (BuildConfig.DEBUG) android.util.Log.i("KeybridgeAutofill", outcome);
  }

  @Override
  public void onSaveRequest(SaveRequest request, SaveCallback callback) {
    callback.onFailure("Keybridge is a read-only mirror.");
  }
}
