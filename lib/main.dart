import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

// Constants
const String appName = 'mxonlive';
const String configUrl = 'https://raw.githubusercontent.com/mxonlive/mxonlive.github.io/refs/heads/main/live/mxonlive_config.json';  // Hardcoded URL for server JSON (assume hosted here)
const String defaultM3uUrl = 'https://raw.githubusercontent.com/mxonlive/mxonlive.github.io/refs/heads/main/live/mxonlive_bdix.m3u';  // Fallback M3U
const String cacheConfigKey = 'cached_config';
const String cachePlaylistKey = 'cached_playlist';
const Duration timeoutDuration = Duration(seconds: 30);

// Models
class ServerConfig {
  final String name;
  final String version;
  final String welcomeMessage;
  final String notification;
  final String m3uUrl;
  final String updateTitle;
  final String updateDescription;
  final String apkDownload;
  final String webDownload;
  final String disclaimer;
  final String creditsPlatform;
  final String telegramUser;
  final String telegramGroup;
  final String website;
  final bool welcomeEnabled;
  final bool notificationEnabled;

  ServerConfig({
    required this.name,
    required this.version,
    required this.welcomeMessage,
    required this.notification,
    required this.m3uUrl,
    required this.updateTitle,
    required this.updateDescription,
    required this.apkDownload,
    required this.webDownload,
    required this.disclaimer,
    required this.creditsPlatform,
    required this.telegramUser,
    required this.telegramGroup,
    required this.website,
    required this.welcomeEnabled,
    required this.notificationEnabled,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      name: json['app']['name'] as String? ?? appName,
      version: json['app']['version'] as String? ?? '1.0.0',
      welcomeMessage: json['app']['welcome_message'] as String? ?? 'Welcome to mxonlive',
      notification: json['app']['notification'] as String? ?? '',
      m3uUrl: json['app']['m3u_url'] as String? ?? defaultM3uUrl,
      updateTitle: json['updates']['title'] as String? ?? "What's New",
      updateDescription: json['updates']['description'] as String? ?? '',
      apkDownload: json['downloads']['apk'] as String? ?? '',
      webDownload: json['downloads']['web'] as String? ?? '',
      disclaimer: json['legal']['disclaimer'] as String? ?? '',
      creditsPlatform: json['credits']['platform'] as String? ?? '',
      telegramUser: json['contact']['telegram_user'] as String? ?? '',
      telegramGroup: json['contact']['telegram_group'] as String? ?? '',
      website: json['contact']['website'] as String? ?? '',
      welcomeEnabled: json['features']['welcome_enabled'] as bool? ?? true,
      notificationEnabled: json['features']['notification_enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'app': {
        'name': name,
        'version': version,
        'welcome_message': welcomeMessage,
        'notification': notification,
        'm3u_url': m3uUrl,
      },
      'updates': {
        'title': updateTitle,
        'description': updateDescription,
      },
      'downloads': {
        'apk': apkDownload,
        'web': webDownload,
      },
      'legal': {'disclaimer': disclaimer},
      'credits': {'platform': creditsPlatform},
      'contact': {
        'telegram_user': telegramUser,
        'telegram_group': telegramGroup,
        'website': website,
      },
      'features': {
        'welcome_enabled': welcomeEnabled,
        'notification_enabled': notificationEnabled,
      },
    };
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

// Services
class ApiService {
  static Future<ServerConfig> fetchConfig() async {
    try {
      final response = await http.get(Uri.parse(configUrl)).timeout(timeoutDuration);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final config = ServerConfig.fromJson(json);
        await _cacheConfig(config);
        return config;
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      final cached = await _getCachedConfig();
      if (cached != null) return cached;
      rethrow;
    }
  }

  static Future<String> fetchPlaylist(String m3uUrl) async {
    try {
      final response = await http.get(Uri.parse(m3uUrl)).timeout(timeoutDuration);
      if (response.statusCode == 200) {
        await _cachePlaylist(response.body);
        return response.body;
      } else {
        throw Exception('Playlist fetch failed: ${response.statusCode}');
      }
    } catch (e) {
      final cached = await _getCachedPlaylist();
      if (cached != null) return cached;
      rethrow;
    }
  }

  static Future<void> _cacheConfig(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheConfigKey, jsonEncode(config.toJson()));
  }

  static Future<ServerConfig?> _getCachedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(cacheConfigKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        return ServerConfig.fromJson(jsonDecode(jsonStr));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Future<void> _cachePlaylist(String playlist) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cachePlaylistKey, playlist);
  }

  static Future<String?> _getCachedPlaylist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(cachePlaylistKey);
  }
}

class PlaylistService {
  static List<Channel> parseM3u(String m3uContent) {
    final lines = m3uContent.split('\n');
    final channels = <Channel>[];

    String? currentName;
    String? currentLogo;
    String? currentGroup;
    String? currentUrl;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('#EXTINF:')) {
        // Parse attributes
        final regex = RegExp(r'tvg-logo="([^"]*)"|group-title="([^"]*)"');
        final matches = regex.allMatches(trimmed);

        currentLogo = matches
            .map((m) => m.group(1))
            .firstWhere((v) => v != null, orElse: () => null);

        currentGroup = matches
            .map((m) => m.group(2))
            .firstWhere((v) => v != null, orElse: () => null);

        // Name is after the last comma
        final namePart = trimmed.split(',').last.trim();
        currentName = namePart.isNotEmpty ? namePart : 'Unknown Channel';
      } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        currentUrl = trimmed;

        // Only add if we have name and valid url
        if (currentName != null && currentUrl.isNotEmpty) {
          channels.add(Channel(
            name: currentName,
            logo: currentLogo ?? '',
            groupTitle: currentGroup ?? 'Uncategorized',
            url: currentUrl,
          ));
        }

        // Reset for next channel
        currentName = null;
        currentLogo = null;
        currentGroup = null;
        currentUrl = null;
      }
    }

    return channels;
  }
}

// UI
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      theme: ThemeData.dark(useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ServerConfig? _config;
  List<Channel> _channels = [];
  List<Channel> _filteredChannels = [];
  bool _isLoading = true;
  String _errorMessage = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadEverything();
    _searchController.addListener(_onSearchChanged);
  }

  Future<void> _loadEverything() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final config = await ApiService.fetchConfig();
      final playlistText = await ApiService.fetchPlaylist(config.m3uUrl);
      final parsedChannels = PlaylistService.parseM3u(playlistText);

      setState(() {
        _config = config;
        _channels = parsedChannels;
        _filteredChannels = parsedChannels;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      if (query.isEmpty) {
        _filteredChannels = _channels;
      } else {
        _filteredChannels = _channels.where((ch) {
          return ch.name.toLowerCase().contains(query) ||
              ch.groupTitle.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
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
            icon: const Icon(Icons.info),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => InfoPage(config: _config),
                ),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadEverything,
        child: _isLoading
            ? _buildLoading()
            : _errorMessage.isNotEmpty
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
        itemCount: 20,
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red[400]),
          const SizedBox(height: 16),
          Text(
            'Something went wrong',
            style: TextStyle(fontSize: 20, color: Colors.red[300]),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _loadEverything,
            icon: const Icon(Icons.refresh),
            label: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return CustomScrollView(
      slivers: [
        if (_config != null && _config!.welcomeEnabled)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _config!.welcomeMessage,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        if (_config != null && _config!.notificationEnabled && _config!.notification.isNotEmpty)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.blue[800],
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                _config!.notification,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search channels...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[850],
              ),
            ),
          ),
        ),

        if (_filteredChannels.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'No channels found',
                style: TextStyle(fontSize: 18, color: Colors.grey),
              ),
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
                  final channel = _filteredChannels[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlayerPage(
                            initialChannel: channel,
                            sameGroupChannels: _channels
                                .where((c) => c.groupTitle == channel.groupTitle)
                                .toList(),
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
                                    errorBuilder: (_, __, ___) => const Icon(Icons.tv, size: 48),
                                  )
                                : const Icon(Icons.tv, size: 48),
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
                childCount: _filteredChannels.length,
              ),
            ),
          ),
      ],
    );
  }
}

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
  late VideoPlayerController _videoController;
  ChewieController? _chewieController;
  late Channel _currentChannel;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.initialChannel;
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(_currentChannel.url),
      );

      await _videoController.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoController,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: true,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              errorMessage,
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _playNewChannel(Channel channel) {
    if (_currentChannel.url == channel.url) return;

    _chewieController?.pause();
    _chewieController?.dispose();
    _videoController.dispose();

    _currentChannel = channel;
    _initializePlayer();
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentChannel.name),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Error: $_error'),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _initializePlayer,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
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
                  selectedTileColor: Colors.blue[900],
                  leading: ch.logo.isNotEmpty
                      ? Image.network(ch.logo, width: 40, errorBuilder: (_, __, ___) => const Icon(Icons.tv))
                      : const Icon(Icons.tv),
                  title: Text(ch.name),
                  onTap: () => _playNewChannel(ch),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class InfoPage extends StatelessWidget {
  final ServerConfig? config;

  const InfoPage({super.key, this.config});

  Future<void> _launch(String url) async {
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
        padding: const EdgeInsets.all(16),
        children: [
          if (config != null) ...[
            Text(
              '${config!.name} • v${config!.version}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),

            const Text('What\'s New', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(config!.updateDescription.isEmpty ? 'Latest improvements' : config!.updateDescription),

            const SizedBox(height: 24),
            const Text('Downloads', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (config!.apkDownload.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _launch(config!.apkDownload),
                icon: const Icon(Icons.android),
                label: const Text('Download APK'),
              ),
            const SizedBox(height: 12),
            if (config!.webDownload.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _launch(config!.webDownload),
                icon: const Icon(Icons.language),
                label: const Text('Open Web Version'),
              ),

            const SizedBox(height: 32),
            const Text('Legal', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(config!.disclaimer),

            const SizedBox(height: 32),
            const Text('Contact', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (config!.telegramUser.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _launch(config!.telegramUser),
                icon: const Icon(Icons.telegram),
                label: const Text('Telegram (Personal)'),
              ),
            const SizedBox(height: 12),
            if (config!.telegramGroup.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _launch(config!.telegramGroup),
                icon: const Icon(Icons.group),
                label: const Text('Telegram Group'),
              ),
            const SizedBox(height: 12),
            if (config!.website.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _launch(config!.website),
                icon: const Icon(Icons.web),
                label: const Text('Website'),
              ),

            const SizedBox(height: 48),
            const Center(
              child: Text(
                'Web Developer: Sultan Muhammad A\'rabi',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ),
            const SizedBox(height: 32),
          ] else ...[
            const Center(child: Text('No configuration loaded yet')),
          ],
        ],
      ),
    );
  }
}
