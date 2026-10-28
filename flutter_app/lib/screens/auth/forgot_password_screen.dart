import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../services/api_service.dart';

enum _RecoveryStage { enterDetails, verifyOtp, emailSent, success }

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  _RecoveryStage _stage = _RecoveryStage.enterDetails;
  String? _errorMessage;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _requestRecovery() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _errorMessage = 'Enter a valid college email address.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await context.read<ApiService>().requestEmailPasswordRecovery(email);
      if (!mounted) return;
      setState(() => _stage = _RecoveryStage.verifyOtp);
    } catch (error) {
      if (mounted) setState(() => _errorMessage = _messageFrom(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _savePassword() async {
    final password = _passwordController.text;
    if (!RegExp(r'^\d{6}$').hasMatch(_otpController.text.trim())) {
      setState(
        () => _errorMessage = 'Enter the six-digit code from your email.',
      );
      return;
    }
    if (password.length < 8 || password.length > 128) {
      setState(
        () => _errorMessage = 'Use a password between 8 and 128 characters.',
      );
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _errorMessage = 'The passwords do not match.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await context.read<ApiService>().verifyEmailPasswordRecovery(
        email: _emailController.text.trim(),
        otp: _otpController.text.trim(),
        newPassword: password,
      );
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
          'Receive a password recovery code at your college email address.',
          Icons.lock_reset_rounded,
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF2FC),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            children: [
              Icon(Icons.email_outlined, color: Color(0xFF1565C0)),
              SizedBox(width: 10),
              Text(
                'College email',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _requestRecovery(),
          decoration: InputDecoration(
            labelText: 'Registered college email',
            hintText: 'name@nitmz.ac.in',
            prefixIcon: const Icon(Icons.email_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 14),
          _errorBanner(),
        ],
        const SizedBox(height: 20),
        _primaryButton(
          label: 'Send recovery code',
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
          'Check your college email',
          'If this email is registered, a six-digit code has been sent. The code expires in 10 minutes.',
          Icons.mark_email_read_outlined,
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
            labelText: 'Six-digit email code',
            hintText: '••••••',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'New password',
            helperText: '8 to 128 characters',
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          _errorBanner(),
        ],
        const SizedBox(height: 12),
        _primaryButton(
          label: 'Verify code and update password',
          onPressed: _savePassword,
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
