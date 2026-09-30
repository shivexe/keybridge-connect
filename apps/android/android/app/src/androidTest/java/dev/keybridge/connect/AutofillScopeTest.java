package dev.keybridge.connect;

import static org.junit.Assert.*;

import org.junit.Test;

public class AutofillScopeTest {
  private KeybridgeAutofillService.Field field(
      String kind, String origin, boolean secure, boolean focused, Object form) {
    return new KeybridgeAutofillService.Field(null, kind, origin, secure, focused, 0, form);
  }

  @Test
  public void emailOnlyAndPasswordOnlyStepsStaySeparate() {
    for (String kind : new String[] {"username", "password"}) {
      KeybridgeAutofillService.Form request = new KeybridgeAutofillService.Form();
      request.fields.add(field(kind, "https://account.protonvpn.com", true, true, new Object()));
      KeybridgeAutofillService.selectFocusedForm(request);
      assertFalse(request.unsafe);
      assertEquals(java.util.Collections.singletonList(kind), request.kinds);
    }
  }

  @Test
  public void embeddedOriginDoesNotBlockOrReceiveFocusedLogin() {
    KeybridgeAutofillService.Form request = new KeybridgeAutofillService.Form();
    Object form = new Object();
    request.fields.add(field("username", "https://example.com", true, false, form));
    request.fields.add(field("password", "https://example.com", true, true, form));
    request.fields.add(field("password", "https://embedded.invalid", true, false, form));
    request.fields.add(field("password", "https://example.com", true, false, new Object()));
    KeybridgeAutofillService.selectFocusedForm(request);
    assertFalse(request.unsafe);
    assertEquals("https://example.com", request.origin);
    assertEquals(java.util.Arrays.asList("username", "password"), request.kinds);
  }

  @Test
  public void insecureOrAmbiguousFocusNeverReceivesPasswords() {
    KeybridgeAutofillService.Form request = new KeybridgeAutofillService.Form();
    request.fields.add(field("password", "https://example.com", false, true, null));
    KeybridgeAutofillService.selectFocusedForm(request);
    assertTrue(request.unsafe);
    assertTrue(request.ids.isEmpty());
    request = new KeybridgeAutofillService.Form();
    request.fields.add(field("password", "https://example.com", true, true, null));
    request.fields.add(field("password", "https://embedded.invalid", true, true, null));
    KeybridgeAutofillService.selectFocusedForm(request);
    assertTrue(request.unsafe);
    assertTrue(request.ids.isEmpty());
  }
}
