package dev.keybridge.connect;

import android.content.Intent;
import android.widget.*;
import androidx.credentials.*;
import androidx.credentials.provider.*;
import java.util.*;
import org.json.*;

public final class CredentialPickerActivity extends UnlockActivity {
  String pkg, signature;

  @Override
  protected void onUnlocked() {
    try {
      ProviderGetCredentialRequest request =
          PendingIntentHandler.retrieveProviderGetCredentialRequest(getIntent());
      Protocol.check(request != null);
      pkg = request.getCallingAppInfo().getPackageName();
      signature = Matcher.fingerprint(this, pkg);
      Protocol.check(
          request.getCredentialOptions().stream().anyMatch(o -> o instanceof GetPasswordOption));
      List<JSONObject> accounts = new ArrayList<>();
      JSONArray records = vault.records();
      for (int i = 0; i < records.length(); i++) {
        JSONObject row = records.getJSONObject(i);
        if (row.getString("state").equals("active")
            && !row.getString("password").isEmpty()
            && !row.getString("username").isEmpty()) accounts.add(row);
      }
      accounts.sort(Comparator.comparing(r -> r.optString("title").toLowerCase(Locale.ROOT)));
      sheet.accounts(
          pkg,
          "",
          accounts,
          row -> sheet.confirm(row, pkg, "", false, remember -> fill(row), this::onUnlocked),
          null);
    } catch (Exception e) {
      message("Invalid credential request. Nothing was shared.");
    }
  }

  void fill(JSONObject row) {
    authorizePassword(() -> fillAuthorized(row));
  }

  private void fillAuthorized(JSONObject selected) {
    JSONObject row = selected;
    try {
      Protocol.check(vault.unlocked() && signature.equals(Matcher.fingerprint(this, pkg)));
      JSONObject record = vault.record(row.getString("id"));
      Protocol.check(
          record.getString("state").equals("active")
              && !record.getString("password").isEmpty()
              && !record.getString("username").isEmpty());
      Intent result = new Intent();
      PendingIntentHandler.setGetCredentialResponse(
          result,
          new GetCredentialResponse(
              new PasswordCredential(record.getString("username"), record.getString("password"))));
      setResult(RESULT_OK, result);
      finish();
    } catch (Exception e) {
      message("Vault locked or requester changed.");
    }
  }
}
