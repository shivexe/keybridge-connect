package dev.keybridge.connect;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import java.util.*;
import java.util.function.Consumer;
import org.json.JSONObject;

final class AccountSheet {
  final Activity activity;
  final LinearLayout panel, body;
  final int ink, muted, surface, raised, blue, line;
  final boolean dark;

  static android.content.Context darkContext(android.content.Context base) {
    Configuration config = new Configuration(base.getResources().getConfiguration());
    config.uiMode =
        (config.uiMode & ~Configuration.UI_MODE_NIGHT_MASK) | Configuration.UI_MODE_NIGHT_YES;
    return base.createConfigurationContext(config);
  }

  AccountSheet(Activity activity) {
    this.activity = activity;
    dark = true;
    ink = Color.parseColor(dark ? "#F2F2F2" : "#202124");
    muted = Color.parseColor(dark ? "#B1B1B6" : "#62666E");
    surface = Color.parseColor(dark ? "#242426" : "#FAFAFC");
    raised = Color.parseColor(dark ? "#303033" : "#EEF0F4");
    blue = Color.parseColor(dark ? "#409CFF" : "#206BD1");
    line = Color.parseColor(dark ? "#404044" : "#E1E4EA");
    panel = column();
    panel.setPadding(dp(24), dp(12), dp(24), dp(24));
    panel.setBackground(shape(surface, 26));
    panel.setClickable(true);
    FrameLayout root =
        new FrameLayout(activity) {
          @Override
          protected void onSizeChanged(int w, int h, int oldw, int oldh) {
            super.onSizeChanged(w, h, oldw, oldh);
            fitToWindow(this);
          }
        };
    root.setOnClickListener(v -> activity.finish());
    root.setOnApplyWindowInsetsListener(
        (v, insets) -> {
          if (Build.VERSION.SDK_INT >= 30) {
            android.graphics.Insets safe =
                insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
            v.setPadding(safe.left, safe.top, safe.right, safe.bottom);
          } else {
            v.setPadding(
                insets.getSystemWindowInsetLeft(),
                insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(),
                insets.getSystemWindowInsetBottom());
          }
          v.post(() -> fitToWindow(v));
          return insets;
        });
    root.addView(
        panel,
        new FrameLayout.LayoutParams(
            Math.min(activity.getResources().getDisplayMetrics().widthPixels, dp(560)),
            dp(620),
            Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL));
    LinearLayout header = new LinearLayout(activity);
    header.setGravity(Gravity.CENTER_VERTICAL);
    TextView brand = text("Keybridge", 15, true);
    brand.setCompoundDrawablePadding(dp(8));
    header.addView(brand, new LinearLayout.LayoutParams(0, dp(48), 1));
    brand.setGravity(Gravity.CENTER_VERTICAL);
    TextView close = text("×", 28, false);
    close.setGravity(Gravity.CENTER);
    close.setTextColor(muted);
    close.setContentDescription("Close password picker");
    close.setBackground(ripple(surface, 24));
    close.setOnClickListener(v -> activity.finish());
    header.addView(close, new LinearLayout.LayoutParams(dp(48), dp(48)));
    panel.addView(header);
    body = column();
    panel.addView(body, new LinearLayout.LayoutParams(-1, 0, 1));
    activity.setContentView(root);
    activity
        .getWindow()
        .setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                | WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
    root.requestApplyInsets();
  }

  void fitToWindow(View root) {
    if (root.getHeight() == 0) return;
    FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) panel.getLayoutParams();
    int height =
        Math.min(
            dp(620),
            Math.max(
                dp(180),
                root.getHeight() - root.getPaddingBottom() - root.getPaddingTop() - dp(24)));
    if (p.height != height) {
      p.height = height;
      panel.setLayoutParams(p);
    }
  }

  int dp(int n) {
    return Math.round(n * activity.getResources().getDisplayMetrics().density);
  }

  LinearLayout column() {
    LinearLayout view = new LinearLayout(activity);
    view.setOrientation(LinearLayout.VERTICAL);
    return view;
  }

  GradientDrawable shape(int color, int radius) {
    GradientDrawable shape = new GradientDrawable();
    shape.setColor(color);
    shape.setCornerRadius(dp(radius));
    return shape;
  }

  RippleDrawable ripple(int color, int radius) {
    return new RippleDrawable(
        ColorStateList.valueOf(dark ? 0x22FFFFFF : 0x16000000),
        shape(color, radius),
        shape(Color.WHITE, radius));
  }

  TextView text(String value, int size, boolean strong) {
    TextView view = new TextView(activity);
    view.setText(value);
    view.setTextSize(size);
    view.setTextColor(ink);
    view.setTypeface(Typeface.create(strong ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
    view.setLineSpacing(dp(3), 1);
    return view;
  }

  void gap(LinearLayout target, int size) {
    target.addView(new View(activity), new LinearLayout.LayoutParams(1, dp(size)));
  }

  void heading(String title, String subtitle) {
    body.removeAllViews();
    gap(body, 8);
    body.addView(text(title, 25, true));
    gap(body, 8);
    TextView sub = text(subtitle, 14, false);
    sub.setTextColor(muted);
    body.addView(sub);
    gap(body, 22);
  }

  TextView button(String label, boolean primary, Runnable action) {
    TextView button = text(label, 15, true);
    button.setGravity(Gravity.CENTER);
    button.setMinHeight(dp(50));
    button.setPadding(dp(12), dp(12), dp(12), dp(12));
    button.setTextColor(primary ? Color.WHITE : blue);
    button.setBackground(ripple(primary ? Color.rgb(32, 107, 209) : surface, 12));
    button.setOnClickListener(v -> action.run());
    button.setFocusable(true);
    button.setAccessibilityDelegate(
        new View.AccessibilityDelegate() {
          @Override
          public void onInitializeAccessibilityNodeInfo(
              View host, android.view.accessibility.AccessibilityNodeInfo info) {
            super.onInitializeAccessibilityNodeInfo(host, info);
            info.setClassName(Button.class.getName());
          }
        });
    return button;
  }

  String appName(String pkg) {
    try {
      return activity
          .getPackageManager()
          .getApplicationLabel(activity.getPackageManager().getApplicationInfo(pkg, 0))
          .toString();
    } catch (Exception e) {
      return pkg;
    }
  }

  View account(JSONObject row, Runnable action) {
    LinearLayout item = new LinearLayout(activity);
    item.setGravity(Gravity.CENTER_VERTICAL);
    item.setPadding(dp(12), dp(14), dp(12), dp(14));
    item.setMinimumHeight(dp(78));
    String title = row.optString("title", "Password");
    TextView badge =
        text(title.isBlank() ? "K" : title.substring(0, 1).toUpperCase(Locale.ROOT), 20, true);
    badge.setTextColor(blue);
    badge.setGravity(Gravity.CENTER);
    badge.setBackground(shape(raised, 12));
    item.addView(badge, new LinearLayout.LayoutParams(dp(44), dp(44)));
    LinearLayout labels = column();
    labels.setPadding(dp(14), 0, dp(8), 0);
    TextView name = text(title, 16, true);
    name.setMaxLines(2);
    name.setEllipsize(android.text.TextUtils.TruncateAt.END);
    labels.addView(name);
    TextView user =
        text(
            row.optString("username").isEmpty() ? "No username" : row.optString("username"),
            14,
            false);
    user.setTextColor(muted);
    user.setMaxLines(2);
    user.setEllipsize(android.text.TextUtils.TruncateAt.END);
    labels.addView(user);
    item.addView(labels, new LinearLayout.LayoutParams(0, -2, 1));
    if (action != null) {
      TextView arrow = text("›", 24, false);
      arrow.setTextColor(muted);
      item.addView(arrow);
      item.setBackground(ripple(surface, 12));
      item.setOnClickListener(v -> action.run());
      item.setFocusable(true);
      item.setContentDescription(title + ", " + row.optString("username") + ", select password");
    } else item.setBackground(shape(raised, 12));
    return item;
  }

  void accounts(
      String pkg,
      String origin,
      List<JSONObject> rows,
      Consumer<JSONObject> select,
      Runnable verify) {
    heading(
        "Choose a password",
        origin.isEmpty()
            ? "Fill in " + appName(pkg)
            : Matcher.host(origin) + " in " + appName(pkg));
    EditText search = new EditText(activity);
    search.setSingleLine(true);
    search.setTextSize(15);
    search.setTextColor(ink);
    search.setHintTextColor(muted);
    search.setHint("Search accounts");
    search.setContentDescription("Search accounts");
    search.setBackground(shape(raised, 12));
    search.setPadding(dp(16), dp(12), dp(16), dp(12));
    search.setInputType(
        android.text.InputType.TYPE_CLASS_TEXT
            | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
    body.addView(search, new LinearLayout.LayoutParams(-1, dp(50)));
    gap(body, 16);
    TextView count = text("", 12, true);
    count.setTextColor(muted);
    body.addView(count);
    gap(body, 6);
    ScrollView scroll = new ScrollView(activity);
    scroll.setFillViewport(true);
    LinearLayout list = column();
    scroll.addView(list);
    body.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    Runnable filter =
        () -> {
          list.removeAllViews();
          String q = search.getText().toString().toLowerCase(Locale.ROOT);
          int matches = 0;
          for (JSONObject row : rows) {
            if (!(row.optString("title") + " " + row.optString("username"))
                .toLowerCase(Locale.ROOT)
                .contains(q)) continue;
            list.addView(
                account(
                    row,
                    () -> {
                      activity
                          .getSystemService(InputMethodManager.class)
                          .hideSoftInputFromWindow(search.getWindowToken(), 0);
                      select.accept(row);
                    }));
            matches++;
          }
          count.setText(matches == 1 ? "1 available account" : matches + " available accounts");
          if (matches == 0) {
            gap(list, 28);
            list.addView(
                text(
                    q.isEmpty() ? "No saved password here yet" : "No matching accounts", 17, true));
            gap(list, 8);
            TextView empty =
                text(
                    q.isEmpty()
                        ? "Sync this website’s password from your Mac, then try again."
                        : "Try another name or username.",
                    14,
                    false);
            empty.setTextColor(muted);
            list.addView(empty);
          }
        };
    search.addTextChangedListener(
        new TextWatcher() {
          public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

          public void onTextChanged(CharSequence s, int start, int before, int count) {
            filter.run();
          }

          public void afterTextChanged(Editable e) {}
        });
    filter.run();
    gap(body, 8);
    body.addView(
        button(
            "Connection details",
            false,
            () ->
                connection(
                    pkg, origin, verify, () -> accounts(pkg, origin, rows, select, verify))));
    panel.setFocusableInTouchMode(true);
    panel.requestFocus();
  }

  void connection(String pkg, String origin, Runnable verify, Runnable back) {
    heading("Receiving app", "Check where your password will be sent.");
    ScrollView scroll = new ScrollView(activity);
    LinearLayout content = column();
    content.addView(text(appName(pkg), 18, true));
    TextView identity = text(pkg + (origin.isEmpty() ? "" : "\n\n" + origin), 14, false);
    identity.setTextIsSelectable(true);
    content.addView(identity);
    gap(content, 20);
    content.addView(
        text(
            "The app supplies this website address. Only fill if you trust the app and recognize"
                + " the address.",
            14,
            false));
    if (verify != null) {
      gap(content, 12);
      content.addView(button("Check website ownership", false, verify));
    }
    scroll.addView(content);
    body.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    body.addView(button("Back to accounts", true, back));
  }

  void confirm(
      JSONObject row,
      String pkg,
      String origin,
      boolean canRemember,
      Consumer<Boolean> fill,
      Runnable back) {
    confirm(row, pkg, origin, canRemember, false, fill, back);
  }

  void confirm(
      JSONObject row,
      String pkg,
      String origin,
      boolean canRemember,
      boolean usernameOnly,
      Consumer<Boolean> fill,
      Runnable back) {
    heading(
        "Fill in " + appName(pkg) + "?",
        usernameOnly
            ? "Only your email or username will be shared. Check the website before continuing."
            : "Your password will be shared with this app.");
    ScrollView scroll = new ScrollView(activity);
    LinearLayout content = column();
    content.addView(account(row, null));
    gap(content, 20);
    content.addView(text(origin.isEmpty() ? appName(pkg) : Matcher.host(origin), 17, true));
    TextView identity = text(pkg, 12, false);
    identity.setTextColor(muted);
    content.addView(identity);
    gap(content, 10);
    TextView warning =
        text(
            origin.isEmpty()
                ? "Only continue if you recognize and trust this app."
                : "The app supplies this address. Check that it matches the website you opened.",
            14,
            false);
    warning.setTextColor(muted);
    content.addView(warning);
    CheckBox remember = new CheckBox(activity);
    remember.setText("Remember for this account");
    remember.setTextColor(ink);
    remember.setTextSize(14);
    remember.setMinHeight(dp(48));
    remember.setButtonTintList(ColorStateList.valueOf(blue));
    if (canRemember) {
      gap(content, 12);
      content.addView(remember);
    }
    scroll.addView(content);
    body.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    gap(body, 12);
    body.addView(
        button(
            usernameOnly ? "Fill username" : "Fill password",
            true,
            () -> fill.accept(remember.isChecked())));
    gap(body, 4);
    body.addView(button("Back to accounts", false, back));
  }

  void message(String title, String explanation, String action, Runnable callback) {
    heading(title, explanation);
    body.addView(new View(activity), new LinearLayout.LayoutParams(1, 0, 1));
    body.addView(button(action, true, callback));
  }
}
