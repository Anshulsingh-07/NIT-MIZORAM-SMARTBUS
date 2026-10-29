function doPost(e) {
  var payload;
  try {
    payload = JSON.parse(e && e.postData && e.postData.contents ? e.postData.contents : '');
  } catch (_) {
    return response({ ok: false, error: 'bad_to' });
  }

  var expectedSecret = PropertiesService.getScriptProperties().getProperty('APPS_SCRIPT_SECRET') || '';
  var providedSecret = String(payload && payload.secret || '');
  if (!expectedSecret || !providedSecret || !constantTimeEqual(providedSecret, expectedSecret)) {
    return response({ ok: false, error: 'unauthorized' });
  }

  try {
    if (!payload || typeof payload.to !== 'string' || !isValidEmail(payload.to)) {
      return response({ ok: false, error: 'bad_to' });
    }
    if (typeof payload.otp !== 'string' || !/^\d{6}$/.test(payload.otp)) {
      return response({ ok: false, error: 'bad_otp' });
    }
    GmailApp.sendEmail(
      payload.to,
      'SmartBus password recovery code',
      'Your SmartBus password recovery code is ' + payload.otp + '. It expires in 10 minutes. If you did not request it, ignore this email.'
    );
    return response({ ok: true });
  } catch (_) {
    return response({ ok: false, error: 'send_failed' });
  }
}

function response(result) {
  return ContentService.createTextOutput(JSON.stringify(result)).setMimeType(ContentService.MimeType.JSON);
}

function isValidEmail(value) {
  return value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function constantTimeEqual(left, right) {
  var difference = left.length ^ right.length;
  var length = Math.max(left.length, right.length);
  for (var index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}
