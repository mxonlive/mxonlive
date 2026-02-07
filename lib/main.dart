import 'dart:async';
import 'dart:convert';

import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

// ================================================
//  APP CONSTANTS
// ================================================

const String appName = 'mxonlive';
const String appVersion = '1.0.0';

// Change this to your real config link when it starts working
const String configUrl = 'https://raw.githubusercontent.com/mxonlive/mxonlive.github.io/refs/heads/main/live/mxonlive_config.json';

// Fallback if config fails
const String fallbackM3uUrl = 'https://private-zone-by-xfireflix.pages.dev/playlist-isp-bdix.m3u';

const Duration requestTimeout = Duration(seconds: 20);

// ================================================
//  MODELS
// ================================================

class AppConfig {
  final String welcomeMessage;
  final String notification;
  final String m3uUrl;
  final String disclaimer;
  final String telegramPersonal;
  final String telegramGroup;
  final String website;
  final String apkDownload;
  final String webUrl;
  final bool showWelcome;
  final bool showNotification;

  AppConfig({
    required this.welcomeMessage,
    required this.notification,
    required this.m3uUrl,
    required this.disclaimer,
    required this.telegramPersonal,
    required this.telegramGroup,
    required this.website,
    required this.apkDownload,
    required this.webUrl,
    required this.showWelcome,
    required this.showNotification,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final app = json['app'] ?? {};
    final updates = json['updates'] ?? {};
    final downloads = json['downloads'] ?? {};
    final legal = json['legal'] ?? {};
    final contact = json['contact'] ?? {};
    final features = json['features'] ?? {};

    return AppConfig(
      welcomeMessage: app['welcome_message']?.toString() ?? 'Welcome to mxonlive',
      notification: app['notification']?.toString() ?? '',
      m3uUrl: app['m3u_url']?.toString() ?? fallbackM3uUrl,
      disclaimer: legal['disclaimer']?.toString() ?? 'mxonlive does not host any content.',
      telegramPersonal: contact['telegram_user']?.toString() ?? 'https://t.me/sultanarabi161',
      telegramGroup: contact['telegram_group']?.toString() ?? 'https://t.me/mxonlive',
      website: contact['website']?.toString() ?? 'https://mxonlive.github.io',
      apkDownload: downloads['apk']?.toString() ?? '',
      webUrl: downloads['web']?.toString() ?? 'https://mxonlive.github.io',
      showWelcome: features['welcome_enabled'] == true,
      showNotification: features['notification_enabled'] == true,
    );
  }
}

class Channel {
  final String name;
  final String logo;
  final String groupTitle;
  final String url;

  Channel({
    required this.name,
    required this.logo,
    required this.groupTitle,
    required this.url,
  });
}

// ================================================
//  MAIN
// ================================================

void main() {
  runApp(const MxOnLive());
}

class MxOnLive extends StatelessWidget {
  const MxOnLive({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// ================================================
//  HOME PAGE
// ================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppConfig? config;
  List<Channel> allChannels = [];
  List<Channel> displayedChannels = [];
  bool isLoading = true;
  String? errorMessage;

  final TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    searchController.addListener(_filterChannels);
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final configData = await _fetchConfig();
      config = AppConfig.fromJson(configData);

      final playlistText = await _fetchPlaylist(config!.m3uUrl);
      final channels = _parseM3U(playlistText);

      setState(() {
        allChannels = channels;
        displayedChannels = channels;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage = _friendlyErrorMessage(e.toString());
      });
    }
  }

  String _friendlyErrorMessage(String error) {
    if (error.contains('SocketException') || error.contains('No address')) {
      return 'ইন্টারনেট সংযোগ নেই বা সার্ভার খুঁজে পাওয়া যাচ্ছে না।\nআপনার ওয়াইফাই/ডাটা চেক করুন।';
    }
    if (error.contains('timeout')) {
      return 'সার্ভারের উত্তর আসতে অনেক সময় লাগছে।\nপরে আবার চেষ্টা করুন।';
    }
    if (error.contains('404') || error.contains('not found')) {
      return 'কনফিগ ফাইল বা প্লেলিস্ট পাওয়া যায়নি।';
    }
    return 'কিছু একটা সমস্যা হয়েছে: $error';
  }

  Future<Map<String, dynamic>> _fetchConfig() async {
    final response = await http.get(Uri.parse(configUrl)).timeout(requestTimeout);
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Config লোড হয়নি (${response.statusCode})');
  }

  Future<String> _fetchPlaylist(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(requestTimeout);
    if (response.statusCode == 200) {
      return response.body;
    }
    throw Exception('প্লেলিস্ট লোড হয়নি (${response.statusCode})');
  }

  List<Channel> _parseM3U(String content) {
    final List<Channel> channels = [];
    String? currentName;
    String? currentLogo;
    String? currentGroup;
    String? currentUrl;

    for (final line in content.split('\n')) {
      final trimmed = line.trim();

      if (trimmed.startsWith('#EXTINF:')) {
        final commaIndex = trimmed.lastIndexOf(',');
        currentName = commaIndex > -1 ? trimmed.substring(commaIndex + 1).trim() : 'Unknown';

        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(trimmed);
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(trimmed);

        currentLogo = logoMatch?.group(1);
        currentGroup = groupMatch?.group(1);
      } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        currentUrl = trimmed;

        if (currentName != null && currentUrl.isNotEmpty) {
          channels.add(Channel(
            name: currentName,
            logo: currentLogo ?? '',
            groupTitle: currentGroup ?? 'Uncategorized',
            url: currentUrl,
          ));
        }

        currentName = null;
        currentLogo = null;
        currentGroup = null;
        currentUrl = null;
      }
    }

    return channels;
  }

  void _filterChannels() {
    final query = searchController.text.trim().toLowerCase();
    setState(() {
      displayedChannels = allChannels.where((ch) {
        return ch.name.toLowerCase().contains(query) ||
            ch.groupTitle.toLowerCase().contains(query);
      }).toList();
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => InfoPage(config: config)),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: isLoading
            ? _buildLoading()
            : errorMessage != null
                ? _buildError()
                : _buildContent(),
      ),
    );
  }

  Widget _buildLoading() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[850]!,
      highlightColor: Colors.grey[700]!,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 0.8,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: 16,
        itemBuilder: (_, __) => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 80, color: Colors.redAccent),
            const SizedBox(height: 24),
            const Text('কিছু একটা সমস্যা হয়েছে', style: TextStyle(fontSize: 22)),
            const SizedBox(height: 16),
            Text(
              errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh),
              label: const Text('আবার চেষ্টা করুন'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return CustomScrollView(
      slivers: [
        // Welcome message
        if (config?.showWelcome == true && config!.welcomeMessage.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                config!.welcomeMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
              ),
            ),
          ),

        // Notification capsule
        if (config?.showNotification == true && config!.notification.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.blue[800],
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Text(
                  config!.notification,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
          ),

        // Search bar
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: 'চ্যানেল খুঁজুন...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.grey[850],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),

        // Channel grid
        if (displayedChannels.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text('কোনো চ্যানেল পাওয়া যায়নি', style: TextStyle(fontSize: 18)),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 0.8,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final channel = displayedChannels[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PlayerPage(
                            initialChannel: channel,
                            sameGroupChannels: allChannels.where((c) => c.groupTitle == channel.groupTitle).toList(),
                          ),
                        ),
                      );
                    },
                    child: Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Expanded(
                            child: channel.logo.isNotEmpty
                                ? Image.network(
                                    channel.logo,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.tv, size: 50),
                                  )
                                : const Icon(Icons.tv, size: 50),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              channel.name,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                childCount: displayedChannels.length,
              ),
            ),
          ),
      ],
    );
  }
}

// ================================================
//  PLAYER PAGE
// ================================================

class PlayerPage extends StatefulWidget {
  final Channel initialChannel;
  final List<Channel> sameGroupChannels;

  const PlayerPage({
    super.key,
    required this.initialChannel,
    required this.sameGroupChannels,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  late Channel _currentChannel;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.initialChannel;
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    setState(() => _errorMessage = null);

    try {
      _videoController?.dispose();
      _chewieController?.dispose();

      _videoController = VideoPlayerController.networkUrl(Uri.parse(_currentChannel.url));
      await _videoController!.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: true,
      );

      setState(() {});
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    }
  }

  void _switchChannel(Channel channel) {
    if (channel.url == _currentChannel.url) return;
    _currentChannel = channel;
    _initializePlayer();
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_currentChannel.name)),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: _errorMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error, color: Colors.red, size: 60),
                          const SizedBox(height: 16),
                          Text('ভিডিও চালানো যায়নি\n$_errorMessage', textAlign: TextAlign.center),
                          const SizedBox(height: 24),
                          ElevatedButton(
                            onPressed: _initializePlayer,
                            child: const Text('আবার চেষ্টা করুন'),
                          ),
                        ],
                      ),
                    ),
                  )
                : _chewieController == null
                    ? const Center(child: CircularProgressIndicator())
                    : Chewie(controller: _chewieController!),
          ),
          Expanded(
            flex: 3,
            child: ListView.builder(
              itemCount: widget.sameGroupChannels.length,
              itemBuilder: (context, index) {
                final ch = widget.sameGroupChannels[index];
                final isActive = ch.url == _currentChannel.url;

                return ListTile(
                  selected: isActive,
                  selectedTileColor: Colors.blueGrey[900],
                  leading: ch.logo.isNotEmpty
                      ? Image.network(ch.logo, width: 40, errorBuilder: (_, __, ___) => const Icon(Icons.tv))
                      : const Icon(Icons.tv),
                  title: Text(ch.name),
                  onTap: () => _switchChannel(ch),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================
//  INFO PAGE
// ================================================

class InfoPage extends StatelessWidget {
  final AppConfig? config;

  const InfoPage({super.key, this.config});

  Future<void> _openLink(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About mxonlive')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '$appName  •  v$appVersion',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),

          if (config != null) ...[
            Text(config!.welcomeMessage, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            Text('Disclaimer:\n${config!.disclaimer}'),
            const SizedBox(height: 32),
            if (config!.apkDownload.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _openLink(config!.apkDownload),
                icon: const Icon(Icons.android),
                label: const Text('Download APK'),
              ),
            const SizedBox(height: 12),
            if (config!.webUrl.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _openLink(config!.webUrl),
                icon: const Icon(Icons.web),
                label: const Text('Website'),
              ),
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.telegramPersonal),
              icon: const Icon(Icons.telegram),
              label: const Text('Telegram Personal'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.telegramGroup),
              icon: const Icon(Icons.group),
              label: const Text('Telegram Group'),
            ),
          ],

          const SizedBox(height: 60),
          const Center(
            child: Text(
              "Web Developer: Sultan Muhammad A'rabi",
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
