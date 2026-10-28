import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../services/api_service.dart';

enum _RecoveryMethod { mobile, email }

enum _RecoveryStage {
  enterDetails,
  verifyOtp,
  createPassword,
  emailSent,
  success,
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _mobileController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  _RecoveryMethod _method = _RecoveryMethod.mobile;
  _RecoveryStage _stage = _RecoveryStage.enterDetails;
  Timer? _countdownTimer;
  String? _resetToken;
  String? _errorMessage;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;
  int _otpSecondsRemaining = 0;
  int _resendSecondsRemaining = 0;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _emailController.dispose();
    _mobileController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _requestRecovery() async {
    if (_isLoading) return;
    final destination = _method == _RecoveryMethod.email
        ? _emailController.text.trim()
        : _mobileController.text.trim();
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _errorMessage = 'Enter a valid college email address.');
      return;
    }
    if (_method == _RecoveryMethod.mobile &&
        !RegExp(
          r'^(?:\+?91[ -]?)?[6-9]\d{9}$',
        ).hasMatch(destination.replaceAll(RegExp(r'[()\s-]'), ''))) {
      setState(
        () => _errorMessage = 'Enter a valid 10-digit Indian mobile number.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await context.read<ApiService>().requestPasswordRecovery(
        method: _method == _RecoveryMethod.email ? 'email' : 'mobile',
        destination: destination,
        accountEmail: _method == _RecoveryMethod.mobile ? email : null,
      );
      if (!mounted) return;
      if (_method == _RecoveryMethod.email) {
        setState(() => _stage = _RecoveryStage.emailSent);
      } else {
        setState(() => _stage = _RecoveryStage.verifyOtp);
        _startOtpCountdown();
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = _messageFrom(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _startOtpCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _otpSecondsRemaining = 5 * 60;
      _resendSecondsRemaining = 60;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted ||
          (_otpSecondsRemaining == 0 && _resendSecondsRemaining == 0)) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_otpSecondsRemaining > 0) _otpSecondsRemaining--;
        if (_resendSecondsRemaining > 0) _resendSecondsRemaining--;
      });
    });
  }

  Future<void> _resendOtp() async {
    if (_isLoading || _resendSecondsRemaining > 0) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await context.read<ApiService>().resendPasswordResetOtp(
        _emailController.text.trim(),
        _mobileController.text.trim(),
      );
      if (mounted) _startOtpCountdown();
    } catch (error) {
      if (mounted) setState(() => _errorMessage = _messageFrom(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyOtp() async {
    if (_otpSecondsRemaining == 0) {
      setState(
        () => _errorMessage = 'This code has expired. Request a new code.',
      );
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_otpController.text.trim())) {
      setState(() => _errorMessage = 'Enter the six-digit code.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      _resetToken = await context.read<ApiService>().verifyPasswordResetOtp(
        _emailController.text.trim(),
        _mobileController.text.trim(),
        _otpController.text.trim(),
      );
      if (mounted) {
        _countdownTimer?.cancel();
        setState(() => _stage = _RecoveryStage.createPassword);
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = _messageFrom(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _savePassword() async {
    final password = _passwordController.text;
    if (password.length < 9 || password.length > 128) {
      setState(
        () => _errorMessage = 'Use a password between 9 and 128 characters.',
      );
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _errorMessage = 'The passwords do not match.');
      return;
    }
    final token = _resetToken;
    if (token == null) {
      setState(
        () => _errorMessage = 'Your verification has expired. Start again.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await context.read<ApiService>().resetPassword(token, password);
      if (mounted) setState(() => _stage = _RecoveryStage.success);
    } catch (error) {
      if (mounted) setState(() => _errorMessage = _messageFrom(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _messageFrom(Object error) {
    if (error is TimeoutException) {
      return 'The server is taking longer than expected. Please try again.';
    }
    if (error is http.ClientException) {
      return 'Unable to connect to the server. Please try again.';
    }
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('TimeoutException') ||
        message.contains('SocketException') ||
        message.contains('ClientException')) {
      return 'Unable to connect to the server. Please try again.';
    }
    if (!error.toString().startsWith('Exception: ')) {
      return 'Unable to complete password recovery. Please try again.';
    }
    return message;
  }

  String _formatDuration(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  void _backToLogin() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        title: const Text('Password recovery'),
        backgroundColor: const Color(0xFFF4F7FB),
        foregroundColor: const Color(0xFF172B44),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _buildStage(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStage() {
    return switch (_stage) {
      _RecoveryStage.enterDetails => _buildDetailsStage(),
      _RecoveryStage.verifyOtp => _buildOtpStage(),
      _RecoveryStage.createPassword => _buildPasswordStage(),
      _RecoveryStage.emailSent => _buildEmailSentStage(),
      _RecoveryStage.success => _buildSuccessStage(),
    };
  }

  Widget _panel({required Widget child}) => Container(
    key: ValueKey(_stage),
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF163A63).withValues(alpha: 0.08),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: child,
  );

  Widget _heading(String title, String description, IconData icon) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFF1565C0).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Icon(icon, color: const Color(0xFF1565C0)),
      ),
      const SizedBox(height: 18),
      Text(
        title,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: const Color(0xFF172B44),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        description,
        style: TextStyle(color: Colors.blueGrey.shade600, height: 1.45),
      ),
    ],
  );

  Widget _buildDetailsStage() => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Get back on the move',
          'Choose a recovery method linked to your account.',
          Icons.lock_reset_rounded,
        ),
        const SizedBox(height: 24),
        SegmentedButton<_RecoveryMethod>(
          segments: const [
            ButtonSegment(
              value: _RecoveryMethod.mobile,
              icon: Icon(Icons.sms_outlined),
              label: Text('Mobile OTP'),
            ),
            ButtonSegment(
              value: _RecoveryMethod.email,
              icon: Icon(Icons.email_outlined),
              label: Text('College email'),
            ),
          ],
          selected: {_method},
          onSelectionChanged: (selection) {
            setState(() {
              _method = selection.first;
              _errorMessage = null;
            });
          },
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: _method == _RecoveryMethod.mobile
              ? TextInputAction.next
              : TextInputAction.done,
          onSubmitted: _method == _RecoveryMethod.email
              ? (_) => _requestRecovery()
              : null,
          decoration: InputDecoration(
            labelText: 'Registered college email',
            hintText: 'name@nitmz.ac.in',
            prefixIcon: const Icon(Icons.email_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        if (_method == _RecoveryMethod.mobile) ...[
          const SizedBox(height: 14),
          TextField(
            controller: _mobileController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _requestRecovery(),
            decoration: InputDecoration(
              labelText: 'Registered mobile number',
              hintText: '+91 98765 43210',
              prefixIcon: const Icon(Icons.phone_iphone),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 14),
          _errorBanner(),
        ],
        const SizedBox(height: 20),
        _primaryButton(
          label: _method == _RecoveryMethod.email
              ? 'Send reset link'
              : 'Send code',
          onPressed: _requestRecovery,
        ),
      ],
    ),
  );

  Widget _buildOtpStage() => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Recovery request accepted',
          'If this number matches a verified account and SMS delivery succeeds, a code will arrive. Delivery is not confirmed. If no code arrives, try email recovery or resend later.',
          Icons.sms_outlined,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: 6,
          ),
          decoration: InputDecoration(
            labelText: 'One-time code',
            hintText: '••••••',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _otpSecondsRemaining > 0
                  ? 'Code expires in ${_formatDuration(_otpSecondsRemaining)}'
                  : 'Code expired',
              style: TextStyle(
                color: _otpSecondsRemaining > 0
                    ? Colors.blueGrey.shade600
                    : Colors.red.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _resendSecondsRemaining == 0 && !_isLoading
                    ? _resendOtp
                    : null,
                child: Text(
                  _resendSecondsRemaining == 0
                      ? 'Resend code'
                      : 'Resend in ${_resendSecondsRemaining}s',
                ),
              ),
            ),
          ],
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          _errorBanner(),
        ],
        const SizedBox(height: 12),
        _primaryButton(
          label: 'Verify code',
          onPressed: _verifyOtp,
          disabled: _otpSecondsRemaining == 0,
        ),
      ],
    ),
  );

  Widget _buildPasswordStage() => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Create a new password',
          'Choose a strong password you have not used for this account.',
          Icons.password_rounded,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'New password',
            helperText: '9 to 128 characters',
            suffixIcon: IconButton(
              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmController,
          obscureText: _obscureConfirmation,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _savePassword(),
          decoration: InputDecoration(
            labelText: 'Confirm new password',
            suffixIcon: IconButton(
              tooltip: _obscureConfirmation ? 'Show password' : 'Hide password',
              onPressed: () =>
                  setState(() => _obscureConfirmation = !_obscureConfirmation),
              icon: Icon(
                _obscureConfirmation ? Icons.visibility_off : Icons.visibility,
              ),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 14),
          _errorBanner(),
        ],
        const SizedBox(height: 20),
        _primaryButton(label: 'Update password', onPressed: _savePassword),
      ],
    ),
  );

  Widget _buildEmailSentStage() => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Recovery request accepted',
          'Delivery is not confirmed. If an account exists and email delivery succeeds, a reset link will arrive. The link expires after 15 minutes.',
          Icons.mark_email_read_outlined,
        ),
        const SizedBox(height: 24),
        _primaryButton(label: 'Back to login', onPressed: _backToLogin),
      ],
    ),
  );

  Widget _buildSuccessStage() => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'You’re all set',
          'Your password has been reset successfully. Please log in using your new password.',
          Icons.check_circle_outline_rounded,
        ),
        const SizedBox(height: 24),
        _primaryButton(label: 'Back to login', onPressed: _backToLogin),
      ],
    ),
  );

  Widget _errorBanner() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF0ED),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFF4C0B8)),
    ),
    child: Text(
      _errorMessage!,
      style: const TextStyle(color: Color(0xFF9C3425), fontSize: 13),
    ),
  );

  Widget _primaryButton({
    required String label,
    required VoidCallback onPressed,
    bool disabled = false,
  }) => SizedBox(
    width: double.infinity,
    height: 52,
    child: FilledButton(
      onPressed: _isLoading || disabled ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF1565C0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: _isLoading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}
