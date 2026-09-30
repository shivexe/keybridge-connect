package dev.keybridge.fixture;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.widget.*;

public final class LoginActivity extends Activity {
  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    String mode = getIntent().getStringExtra("mode");
    if ("web".equals(mode) || "attack".equals(mode)) {
      android.webkit.WebView web = new android.webkit.WebView(this);
      web.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_YES);
      web.loadDataWithBaseURL(
          "attack".equals(mode)
              ? "https://login0.example.test.attacker.test"
              : "https://login0.example.test",
          "<html><meta name='viewport'"
              + " content='width=device-width,initial-scale=1'><body><h3>Synthetic"
              + " WebView</h3><form><input id='user' autocomplete='username'"
              + " placeholder='Username'><br><input id='pass' type='password'"
              + " autocomplete='current-password' placeholder='Password'></form><p>Nothing"
              + " submitted</p></body></html>",
          "text/html",
          "UTF-8",
          null);
      setContentView(web);
      return;
    }
    LinearLayout layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    layout.setPadding(32, 48, 32, 32);
    TextView title = new TextView(this);
    title.setText("Synthetic login fixture — never submits");
    layout.addView(title);
    EditText user = new EditText(this);
    user.setId(R.id.username);
    user.setHint("Username");
    user.setAutofillHints(View.AUTOFILL_HINT_USERNAME);
    layout.addView(user);
    EditText pass = new EditText(this);
    pass.setId(R.id.password);
    pass.setHint("Password");
    pass.setInputType(0x81);
    pass.setAutofillHints(View.AUTOFILL_HINT_PASSWORD);
    layout.addView(pass);
    Button next = new Button(this);
    next.setText("Username-first test");
    next.setOnClickListener(
        v -> {
          layout.removeView(user);
          pass.requestFocus();
        });
    layout.addView(next);
    TextView status = new TextView(this);
    status.setText("Nothing submitted");
    layout.addView(status);
    android.text.TextWatcher watcher =
        new android.text.TextWatcher() {
          public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

          public void onTextChanged(CharSequence s, int start, int before, int count) {
            status.setText(
                user.getText().toString().startsWith("dummy")
                        && pass.getText().toString().startsWith("KB_SYNTHETIC_CANARY_")
                    ? "Local fill verified; nothing submitted"
                    : "Nothing submitted");
          }

          public void afterTextChanged(android.text.Editable e) {}
        };
    user.addTextChangedListener(watcher);
    pass.addTextChangedListener(watcher);
    if (android.os.Build.VERSION.SDK_INT >= 34) {
      Button credentials = new Button(this);
      credentials.setText("Request saved password");
      credentials.setOnClickListener(
          v -> {
            androidx.credentials.GetCredentialRequest request =
                new androidx.credentials.GetCredentialRequest.Builder()
                    .addCredentialOption(new androidx.credentials.GetPasswordOption())
                    .build();
            androidx.credentials.CredentialManager.create(this)
                .getCredentialAsync(
                    this,
                    request,
                    null,
                    getMainExecutor(),
                    new androidx.credentials.CredentialManagerCallback<
                        androidx.credentials.GetCredentialResponse,
                        androidx.credentials.exceptions.GetCredentialException>() {
                      public void onResult(androidx.credentials.GetCredentialResponse response) {
                        if (response.getCredential()
                            instanceof androidx.credentials.PasswordCredential) {
                          androidx.credentials.PasswordCredential p =
                              (androidx.credentials.PasswordCredential) response.getCredential();
                          user.setText(p.getId());
                          pass.setText(p.getPassword());
                        }
                      }

                      public void onError(
                          androidx.credentials.exceptions.GetCredentialException e) {
                        status.setText("Credential request cancelled or unavailable");
                      }
                    });
          });
      layout.addView(credentials);
    }
    setContentView(layout);
  }
}
