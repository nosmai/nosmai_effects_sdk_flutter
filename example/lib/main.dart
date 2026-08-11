import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
import 'unified_camera_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NosmaiCameraApp());
}

class NosmaiCameraApp extends StatelessWidget {
  const NosmaiCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nosmai Effects',
      theme: _buildAppTheme(),
      home: const HomePage(),
    );
  }

  ThemeData _buildAppTheme() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6C5CE7),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isLoading = false;

  // Theme colors
  static const Color _primaryColor = Color(0xFF6C5CE7);
  static const Color _backgroundColor = Color(0xFF0A0A0A);
  static const Color _surfaceColor = Color(0xFF1A1A1A);

  static const Color _effectsColor = Color(0xFF6C5CE7);
  static const Color _beautyColor = Color(0xFFFF6B6B);
  static const Color _colorColor = Color(0xFF4ECDC4);
  static const Color _recordColor = Color(0xFFFFD93D);

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final screenHeight = screenSize.height;
    final screenWidth = screenSize.width;
    final isSmallScreen = screenHeight < 700;
    final isVerySmallScreen = screenHeight < 600;

    return Scaffold(
      backgroundColor: _backgroundColor,
      body: Container(
        decoration: _buildBackgroundGradient(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: _buildScreenPadding(
              screenWidth,
              isSmallScreen,
              isVerySmallScreen,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildTopSpacing(isSmallScreen, isVerySmallScreen),
                _buildAppLogo(isSmallScreen, isVerySmallScreen),
                _buildTitleSection(isSmallScreen),
                _buildCameraButton(context, screenWidth, isSmallScreen),
                _buildFeatureGrid(
                  screenWidth,
                  isSmallScreen,
                  isVerySmallScreen,
                ),
                _buildVersionInfo(),
                _buildBottomSpacing(isSmallScreen),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Creates the background gradient decoration
  BoxDecoration _buildBackgroundGradient() {
    return const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_surfaceColor, _backgroundColor],
      ),
    );
  }

  /// Creates responsive padding based on screen size
  EdgeInsets _buildScreenPadding(
    double screenWidth,
    bool isSmallScreen,
    bool isVerySmallScreen,
  ) {
    return EdgeInsets.symmetric(
      horizontal: screenWidth * 0.06,
      vertical: isVerySmallScreen ? 12.0 : (isSmallScreen ? 16.0 : 24.0),
    );
  }

  /// Creates top spacing widget
  Widget _buildTopSpacing(bool isSmallScreen, bool isVerySmallScreen) {
    return SizedBox(height: isVerySmallScreen ? 16 : (isSmallScreen ? 20 : 30));
  }

  /// Creates the app logo/icon widget
  Widget _buildAppLogo(bool isSmallScreen, bool isVerySmallScreen) {
    final size = isVerySmallScreen ? 70.0 : (isSmallScreen ? 80.0 : 100.0);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [_primaryColor, _primaryColor.withAlpha(153)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: _primaryColor.withAlpha(77),
            blurRadius: 30,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Icon(
        Icons.camera_alt_rounded,
        size: isSmallScreen ? 40 : 50,
        color: Colors.white,
      ),
    );
  }

  /// Creates the title section with app name and subtitle
  Widget _buildTitleSection(bool isSmallScreen) {
    return Column(
      children: [
        SizedBox(height: isSmallScreen ? 20 : 30),

        // App Title
        Text(
          'Nosmai Effects',
          style: TextStyle(
            fontSize: isSmallScreen ? 26 : 32,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),

        const SizedBox(height: 8),

        // Subtitle
        Text(
          'Professional filters & effects',
          style: TextStyle(
            fontSize: isSmallScreen ? 14 : 16,
            color: Colors.white.withAlpha(153),
            letterSpacing: 0.5,
          ),
        ),

        SizedBox(height: isSmallScreen ? 24 : 40),
      ],
    );
  }

  /// Creates the main camera button
  Widget _buildCameraButton(
    BuildContext context,
    double screenWidth,
    bool isSmallScreen,
  ) {
    return Column(
      children: [
        GestureDetector(
          onTap: _isLoading ? null : () => _navigateToCamera(context),
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(
              maxWidth: screenWidth * 0.8 > 300 ? 300 : screenWidth * 0.8,
            ),
            height: isSmallScreen ? 48 : 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [_primaryColor, _primaryColor.withAlpha(204)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: _primaryColor.withAlpha(102),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isLoading)
                  SizedBox(
                    width: isSmallScreen ? 20 : 24,
                    height: isSmallScreen ? 20 : 24,
                    child: const CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                else
                  Icon(
                    Icons.camera_enhance_rounded,
                    color: Colors.white,
                    size: isSmallScreen ? 20 : 24,
                  ),
                const SizedBox(width: 12),
                Text(
                  _isLoading ? 'Opening...' : 'Open Camera',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isSmallScreen ? 16 : 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: isSmallScreen ? 24 : 32),
      ],
    );
  }

  void _navigateToCamera(BuildContext context) async {
    setState(() {
      _isLoading = true;
    });

    try {
      final cameraPermission = await Permission.camera.request();
      await Permission.microphone.request();

      if (!NosmaiFlutter.instance.isInitialized) {
        const androidKey = 'NOSMAI_ANDROID_LICENSE_KEY';
        const iosKey = 'NOSMAI_IOS_LICENSE_KEY';
        final licenseKey = Platform.isIOS ? iosKey : androidKey;
        if (licenseKey.isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Nosmai license key is missing.',
                ),
              ),
            );
          }
          return;
        }
        final initialized = await NosmaiFlutter.initialize(licenseKey);
        if (!initialized) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Nosmai SDK initialization failed.'),
              ),
            );
          }
          return;
        }
      }

      if (cameraPermission.isGranted && context.mounted) {
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const UnifiedCameraScreen(),
            transitionDuration: const Duration(milliseconds: 100),
            reverseTransitionDuration: const Duration(milliseconds: 100),
            transitionsBuilder: (
              context,
              animation,
              secondaryAnimation,
              child,
            ) {
              return FadeTransition(opacity: animation, child: child);
            },
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Creates the feature showcase grid
  Widget _buildFeatureGrid(
    double screenWidth,
    bool isSmallScreen,
    bool isVerySmallScreen,
  ) {
    return Column(
      children: [
        Container(
          constraints: BoxConstraints(
            maxWidth: screenWidth > 400 ? 400 : screenWidth * 0.9,
          ),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: isSmallScreen ? 8 : 12,
            mainAxisSpacing: isSmallScreen ? 8 : 12,
            childAspectRatio: isSmallScreen ? 1.8 : 1.6,
            children: [
              _buildFeatureCard(
                icon: Icons.auto_awesome,
                title: 'Effects',
                color: _effectsColor,
                isSmallScreen: isSmallScreen,
                isVerySmallScreen: isVerySmallScreen,
              ),
              _buildFeatureCard(
                icon: Icons.face_retouching_natural,
                title: 'Beauty',
                color: _beautyColor,
                isSmallScreen: isSmallScreen,
                isVerySmallScreen: isVerySmallScreen,
              ),
              _buildFeatureCard(
                icon: Icons.palette_outlined,
                title: 'Color',
                color: _colorColor,
                isSmallScreen: isSmallScreen,
                isVerySmallScreen: isVerySmallScreen,
              ),
              _buildFeatureCard(
                icon: Icons.videocam_rounded,
                title: 'Record',
                color: _recordColor,
                isSmallScreen: isSmallScreen,
                isVerySmallScreen: isVerySmallScreen,
              ),
            ],
          ),
        ),
        SizedBox(height: isSmallScreen ? 16 : 24),
      ],
    );
  }

  /// Creates version information widget
  Widget _buildVersionInfo() {
    return Text(
      'Version 1.0.0',
      style: TextStyle(fontSize: 12, color: Colors.white.withAlpha(77)),
    );
  }

  /// Creates bottom spacing widget
  Widget _buildBottomSpacing(bool isSmallScreen) {
    return SizedBox(height: isSmallScreen ? 16 : 20);
  }

  /// Creates individual feature card widget
  Widget _buildFeatureCard({
    required IconData icon,
    required String title,
    required Color color,
    bool isSmallScreen = false,
    bool isVerySmallScreen = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(26), width: 1),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: EdgeInsets.all(
          isVerySmallScreen ? 8 : (isSmallScreen ? 10 : 14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon container
            Container(
              width: isVerySmallScreen ? 24 : (isSmallScreen ? 28 : 36),
              height: isVerySmallScreen ? 24 : (isSmallScreen ? 28 : 36),
              decoration: BoxDecoration(
                color: color.withAlpha(51),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                color: color,
                size: isVerySmallScreen ? 14 : (isSmallScreen ? 16 : 20),
              ),
            ),

            SizedBox(height: isVerySmallScreen ? 4 : (isSmallScreen ? 6 : 10)),

            // Title
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isVerySmallScreen ? 10 : (isSmallScreen ? 11 : 13),
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),

            const SizedBox(height: 2),

            // Subtitle
          ],
        ),
      ),
    );
  }
}
