function doPost(e) {
  var payload;
  try {
    payload = JSON.parse(e && e.postData && e.postData.contents ? e.postData.contents : '');
  } catch (_) {
    return response('ERROR: invalid request');
  }

  var expectedSecret = PropertiesService.getScriptProperties().getProperty('MAIL_SECRET') || '';
  if (!constantTimeEqual(String(payload && payload.secret || ''), expectedSecret)) {
    return response('ERROR: unauthorized');
  }

  try {
    if (!payload || typeof payload.to !== 'string' || !isValidEmail(payload.to)) {
      return response('ERROR: invalid request');
    }

    var subject;
    var text;
    var html = '';
    if (Object.prototype.hasOwnProperty.call(payload, 'otp')) {
      if (typeof payload.otp !== 'string' || !/^\d{6}$/.test(payload.otp)) {
        return response('ERROR: invalid request');
      }
      subject = typeof payload.subject === 'string' && payload.subject ? payload.subject : 'SmartBus password reset code';
      text = typeof payload.text === 'string' && payload.text
        ? payload.text
        : 'Your SmartBus password reset code is ' + payload.otp + '.';
      html = typeof payload.html === 'string' ? payload.html : '';
    } else {
      if (typeof payload.subject !== 'string' || !payload.subject ||
          typeof payload.text !== 'string' || !payload.text) {
        return response('ERROR: invalid request');
      }
      subject = payload.subject;
      text = payload.text;
      html = typeof payload.html === 'string' ? payload.html : '';
    }

    if (html) {
      GmailApp.sendEmail(payload.to, subject, text, { htmlBody: html });
    } else {
      GmailApp.sendEmail(payload.to, subject, text);
    }
    return response('OK');
  } catch (_) {
    return response('ERROR: email delivery failed');
  }
}

function response(message) {
  return ContentService.createTextOutput(message).setMimeType(ContentService.MimeType.TEXT);
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
