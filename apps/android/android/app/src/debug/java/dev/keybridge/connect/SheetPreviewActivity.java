package dev.keybridge.connect;

import android.os.Bundle;
import android.view.WindowManager;

public final class SheetPreviewActivity extends androidx.fragment.app.FragmentActivity {
  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
  }
}
