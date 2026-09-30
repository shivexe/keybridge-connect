package dev.keybridge.connect;

import android.content.Intent;
import android.service.autofill.Dataset;
import android.view.autofill.*;
import android.widget.*;
import java.util.*;
import org.json.*;

public final class PickerActivity extends UnlockActivity {
  String pkg, signature, origin;

  boolean usernameOnly() {
    return getIntent().getBooleanExtra("accessibility", false)
        && "username".equals(getIntent().getStringExtra("accessibilityKind"));
  }

  @Override
  protected void onUnlocked() {
    try {
      pkg = getIntent().getStringExtra("package");
      signature = getIntent().getStringExtra("signature");
      origin = getIntent().getStringExtra("origin");
      Protocol.check(
          pkg != null
              && signature != null
              && origin != null
              && signature.equals(Matcher.fingerprint(this, pkg)));
      List<JSONObject> accounts = new ArrayList<>();
      JSONArray records = vault.records();
      for (int i = 0; i < records.length(); i++) {
        JSONObject row = records.getJSONObject(i);
        if (!row.getString("state").equals("active") || row.getString("password").isEmpty())
          continue;
        if (!origin.isEmpty() && !Matcher.matchesOrigin(row, origin)) continue;
        accounts.add(row);
      }
      accounts.sort(Comparator.comparing(r -> r.optString("title").toLowerCase(Locale.ROOT)));
      sheet.accounts(pkg, origin, accounts, this::select, origin.isEmpty() ? null : this::verify);
    } catch (Exception e) {
      message("Request changed or vault locked. Try filling again.");
    }
  }

  void verify() {
    sheet.message(
        "Checking website ownership",
        "Checking whether the website authorizes this app…",
        "Back to accounts",
        this::onUnlocked);
    new Thread(
            () -> {
              String result;
              try {
                boolean trusted = AssetLinks.verify(this, origin, pkg, signature);
                if (trusted) {
                  JSONObject state = vault.read();
                  JSONArray verified = state.optJSONArray("verifiedOrigins");
                  if (verified == null) verified = new JSONArray();
                  verified.put(
                      Protocol.obj(
                          "package",
                          pkg,
                          "signature",
                          signature,
                          "host",
                          Matcher.host(origin),
                          "expiresAt",
                          System.currentTimeMillis() / 1000 + 86400));
                  state.put("verifiedOrigins", verified);
                  vault.commit(state);
                }
                result =
                    trusted
                        ? "The website confirms that this app can receive its passwords."
                        : "The website hasn’t confirmed this app. You can still review and approve"
                            + " a fill yourself.";
              } catch (Exception e) {
                result =
                    "Couldn’t reach the website. You can still review and approve a fill yourself.";
              }
              String explanation = result;
              runOnUiThread(
                  () -> {
                    if (!isFinishing())
                      sheet.message(
                          "Website ownership", explanation, "Back to accounts", this::onUnlocked);
                  });
            })
        .start();
  }

  void select(JSONObject row) {
    try {
      String id = row.getString("id");
      if (!usernameOnly() && Matcher.associated(vault, pkg, signature, origin, id)) {
        fill(row);
        return;
      }
      sheet.confirm(
          row,
          pkg,
          origin,
          !usernameOnly(),
          usernameOnly(),
          remember -> {
            try {
              fill(row, remember);
            } catch (Exception e) {
              message("Couldn’t remember this app. Try filling again.");
            }
          },
          this::onUnlocked);
    } catch (Exception e) {
      message("Vault locked.");
    }
  }

  void fill(JSONObject row) {
    fill(row, false);
  }

  void fill(JSONObject row, boolean remember) {
    authorizePassword(
        () -> {
          try {
            if (remember) Matcher.associate(vault, pkg, signature, origin, row.getString("id"));
            fillAuthorized(row);
          } catch (Exception e) {
            message("Couldn’t approve this app. No password was shared.");
          }
        });
  }

  private void fillAuthorized(JSONObject selected) {
    JSONObject row = selected;
    try {
      Protocol.check(vault.unlocked() && signature.equals(Matcher.fingerprint(this, pkg)));
      row = vault.record(row.getString("id"));
      Protocol.check(
          row.getString("state").equals("active") && !row.getString("password").isEmpty());
      Protocol.check(origin.isEmpty() || Matcher.matchesOrigin(row, origin));
      if (getIntent().getBooleanExtra("accessibility", false)) {
        Protocol.check(
            KeybridgeAccessibilityService.fill(
                this,
                pkg,
                signature,
                getIntent().getIntExtra("window", -1),
                getIntent().getStringExtra("node"),
                getIntent().getStringExtra("accessibilityKind"),
                row));
        finish();
        return;
      }
      ArrayList<AutofillId> ids = getIntent().getParcelableArrayListExtra("ids");
      ArrayList<String> kinds = getIntent().getStringArrayListExtra("kinds");
      Protocol.check(ids != null && kinds != null && ids.size() == kinds.size() && !ids.isEmpty());
      RemoteViews presentation =
          new RemoteViews(getPackageName(), android.R.layout.simple_list_item_1);
      presentation.setTextViewText(android.R.id.text1, "Keybridge login");
      Dataset.Builder data = new Dataset.Builder(presentation);
      for (int i = 0; i < ids.size(); i++) {
        String value = row.getString(kinds.get(i));
        if (!value.isEmpty()) data.setValue(ids.get(i), AutofillValue.forText(value));
      }
      setResult(
          RESULT_OK,
          new Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, data.build()));
      finish();
    } catch (Exception e) {
      message("The request changed. No login was filled.");
    }
  }
}
