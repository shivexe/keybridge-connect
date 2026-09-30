package dev.keybridge.connect;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.*;
import androidx.credentials.exceptions.*;
import androidx.credentials.provider.*;

public final class KeybridgeCredentialService extends CredentialProviderService {
  @Override
  public void onBeginGetCredentialRequest(
      BeginGetCredentialRequest request,
      CancellationSignal cancellation,
      OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException> callback) {
    try {
      BeginGetCredentialResponse.Builder result = new BeginGetCredentialResponse.Builder();
      for (BeginGetCredentialOption option : request.getBeginGetCredentialOptions()) {
        if (!(option instanceof BeginGetPasswordOption)) continue;
        Intent intent =
            new Intent(this, CredentialPickerActivity.class)
                .setAction(java.util.UUID.randomUUID().toString());
        PendingIntent pending =
            PendingIntent.getActivity(
                this, 0, intent, PendingIntent.FLAG_MUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        result.addCredentialEntry(
            new PasswordCredentialEntry.Builder(
                    this, "Choose saved login", pending, (BeginGetPasswordOption) option)
                .setDisplayName("Unlock Keybridge Connect")
                .build());
      }
      callback.onResult(result.build());
    } catch (Exception e) {
      callback.onError(new GetCredentialUnknownException("Provider unavailable"));
    }
  }

  @Override
  public void onBeginCreateCredentialRequest(
      BeginCreateCredentialRequest request,
      CancellationSignal cancellation,
      OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException> callback) {
    callback.onError(new CreateCredentialUnsupportedException("Read-only password mirror"));
  }

  @Override
  public void onClearCredentialStateRequest(
      ProviderClearCredentialStateRequest request,
      CancellationSignal cancellation,
      OutcomeReceiver<Void, ClearCredentialException> callback) {
    Vault.get(this).lock();
    callback.onResult(null);
  }
}
