import 'dart:async';
import 'dart:convert';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

// ──────────────────────────────────────────────
//  CONFIG & CONSTANTS
// ──────────────────────────────────────────────

const String appName = 'mxonlive';
const String configUrl = 'https://mxonlive.github.io/live/mxonlive_config.json';
const String defaultM3uUrl = 'https://private-zone-by-xfireflix.pages.dev/playlist-isp-bdix.m3u';

const String cacheConfigKey = 'mxonlive_config_cache';
const String cachePlaylistKey = 'mxonlive_playlist_cache';

const Duration requestTimeout = Duration(seconds: 20);

// ──────────────────────────────────────────────
//  MODELS
// ──────────────────────────────────────────────

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
    required this.telegramUser,
    required this.telegramGroup,
    required this.website,
    required this.welcomeEnabled,
    required this.notificationEnabled,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      name: json['app']?['name'] as String? ?? appName,
      version: json['app']?['version'] as String? ?? '1.0.0',
      welcomeMessage: json['app']?['welcome_message'] as String? ?? 'Welcome to mxonlive',
      notification: json['app']?['notification'] as String? ?? '',
      m3uUrl: json['app']?['m3u_url'] as String? ?? defaultM3uUrl,
      updateTitle: json['updates']?['title'] as String? ?? "What's New",
      updateDescription: json['updates']?['description'] as String? ?? 'Latest improvements',
      apkDownload: json['downloads']?['apk'] as String? ?? '',
      webDownload: json['downloads']?['web'] as String? ?? '',
      disclaimer: json['legal']?['disclaimer'] as String? ?? 'This app does not host any content.',
      telegramUser: json['contact']?['telegram_user'] as String? ?? '',
      telegramGroup: json['contact']?['telegram_group'] as String? ?? '',
      website: json['contact']?['website'] as String? ?? '',
      welcomeEnabled: json['features']?['welcome_enabled'] as bool? ?? true,
      notificationEnabled: json['features']?['notification_enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'app': {
          'name': name,
          'version': version,
          'welcome_message': welcomeMessage,
          'notification': notification,
          'm3u_url': m3uUrl,
        },
        'updates': {'title': updateTitle, 'description': updateDescription},
        'downloads': {'apk': apkDownload, 'web': webDownload},
        'legal': {'disclaimer': disclaimer},
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

// ──────────────────────────────────────────────
//  CACHE HELPER
// ──────────────────────────────────────────────

class CacheHelper {
  static Future<void> saveConfig(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheConfigKey, jsonEncode(config.toJson()));
  }

  static Future<ServerConfig?> getCachedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(cacheConfigKey);
    if (raw == null) return null;
    try {
      return ServerConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> savePlaylist(String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cachePlaylistKey, content);
  }

  static Future<String?> getCachedPlaylist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(cachePlaylistKey);
  }

  static Future<bool> hasAnyCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(cacheConfigKey) || prefs.containsKey(cachePlaylistKey);
  }
}

// ──────────────────────────────────────────────
//  SERVICES
// ──────────────────────────────────────────────

class ConfigService {
  static Future<ServerConfig> load() async {
    try {
      final response = await http.get(Uri.parse(configUrl)).timeout(requestTimeout);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final config = ServerConfig.fromJson(json);
        await CacheHelper.saveConfig(config);
        return config;
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      final cached = await CacheHelper.getCachedConfig();
      if (cached != null) {
        return cached;
      }
      throw Exception('No internet & no cache');
    }
  }
}

class PlaylistService {
  static Future<List<Channel>> loadAndParse(String playlistUrl) async {
    String content = '';

    try {
      final res = await http.get(Uri.parse(playlistUrl)).timeout(requestTimeout);
      if (res.statusCode == 200) {
        content = res.body;
        await CacheHelper.savePlaylist(content);
      }
    } catch (_) {
      // fallback to cache
      content = (await CacheHelper.getCachedPlaylist()) ?? '';
    }

    if (content.trim().isEmpty) {
      return [];
    }

    return _parseM3u(content);
  }

  static List<Channel> _parseM3u(String text) {
    final channels = <Channel>[];
    String? name, logo, group, url;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();

      if (trimmed.startsWith('#EXTINF:')) {
        final parts = trimmed.split(',');
        name = parts.length > 1 ? parts.last.trim() : 'Unknown';

        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(trimmed);
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(trimmed);

        logo = logoMatch?.group(1);
        group = groupMatch?.group(1);
      } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        url = trimmed;

        if (name != null && url.isNotEmpty) {
          channels.add(Channel(
            name: name,
            logo: logo ?? '',
            groupTitle: group ?? 'Uncategorized',
            url: url,
          ));
        }

        name = logo = group = url = null;
      }
    }

    return channels;
  }
}

// ──────────────────────────────────────────────
//  MAIN APP
// ──────────────────────────────────────────────

void main() {
  runApp(const MxOnLiveApp());
}

class MxOnLiveApp extends StatelessWidget {
  const MxOnLiveApp({super.key});

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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ServerConfig? config;
  List<Channel> channels = [];
  List<Channel> filteredChannels = [];
  bool isLoading = true;
  String? errorMessage;
  bool isOfflineMode = false;

  final searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    searchController.addListener(_onSearch);
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
      isOfflineMode = false;
    });

    try {
      final cfg = await ConfigService.load();
      final ch = await PlaylistService.loadAndParse(cfg.m3uUrl);

      setState(() {
        config = cfg;
        channels = ch;
        filteredChannels = ch;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage = e.toString();
        isOfflineMode = await CacheHelper.hasAnyCache();
      });

      // Try to show cached data even if error
      if (isOfflineMode) {
        final cachedConfig = await CacheHelper.getCachedConfig();
        final cachedPlaylist = await CacheHelper.getCachedPlaylist();

        if (cachedConfig != null && cachedPlaylist != null && cachedPlaylist.isNotEmpty) {
          setState(() {
            config = cachedConfig;
            channels = PlaylistService._parseM3u(cachedPlaylist);
            filteredChannels = channels;
            errorMessage = 'Offline mode - using saved data';
          });
        }
      }
    }
  }

  void _onSearch() {
    final query = searchController.text.trim().toLowerCase();
    setState(() {
      filteredChannels = channels.where((c) {
        return c.name.toLowerCase().contains(query) ||
            c.groupTitle.toLowerCase().contains(query);
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
        onRefresh: _loadAllData,
        child: isLoading
            ? _buildShimmer()
            : errorMessage != null
                ? _buildErrorView()
                : _buildMainContent(),
      ),
    );
  }

  Widget _buildShimmer() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[850]!,
      highlightColor: Colors.grey[700]!,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 0.75,
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

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isOfflineMode ? Icons.cloud_off : Icons.error_outline,
              size: 80,
              color: isOfflineMode ? Colors.orange : Colors.redAccent,
            ),
            const SizedBox(height: 24),
            Text(
              isOfflineMode ? 'Offline Mode' : 'Connection Problem',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              errorMessage ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400]),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
              onPressed: _loadAllData,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    return CustomScrollView(
      slivers: [
        if (config?.welcomeEnabled == true)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                config?.welcomeMessage ?? '',
                style: const TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        if (config?.notificationEnabled == true && (config?.notification ?? '').isNotEmpty)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[800],
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                config!.notification,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: 'Search channels...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey[850],
              ),
            ),
          ),
        ),

        if (filteredChannels.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No channels found', style: TextStyle(fontSize: 18))),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 0.75,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final ch = filteredChannels[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlayerPage(
                            initialChannel: ch,
                            groupChannels: channels.where((c) => c.groupTitle == ch.groupTitle).toList(),
                          ),
                        ),
                      );
                    },
                    child: Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        children: [
                          Expanded(
                            child: ch.logo.isNotEmpty
                                ? Image.network(
                                    ch.logo,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.tv, size: 50),
                                  )
                                : const Icon(Icons.tv, size: 50),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              ch.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                childCount: filteredChannels.length,
              ),
            ),
          ),
      ],
    );
  }
}

// Player Page
class PlayerPage extends StatefulWidget {
  final Channel initialChannel;
  final List<Channel> groupChannels;

  const PlayerPage({
    super.key,
    required this.initialChannel,
    required this.groupChannels,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _videoController;
  ChewieController? _chewieController;
  late Channel _currentChannel;
  bool _isBuffering = true;
  String? _playerError;

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.initialChannel;
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    setState(() {
      _isBuffering = true;
      _playerError = null;
    });

    try {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(_currentChannel.url));
      await _videoController.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoController,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowMuting: true,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              'Cannot play stream\n$errorMessage',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );

      setState(() => _isBuffering = false);
    } catch (e) {
      setState(() {
        _playerError = e.toString();
        _isBuffering = false;
      });
    }
  }

  void _switchTo(Channel channel) {
    if (channel.url == _currentChannel.url) return;

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
      appBar: AppBar(title: Text(_currentChannel.name)),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: _isBuffering
                ? const Center(child: CircularProgressIndicator())
                : _playerError != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error, color: Colors.red, size: 60),
                            const SizedBox(height: 16),
                            Text('Stream error\n$_playerError', textAlign: TextAlign.center),
                            const SizedBox(height: 24),
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
              itemCount: widget.groupChannels.length,
              itemBuilder: (context, index) {
                final ch = widget.groupChannels[index];
                final isPlaying = ch.url == _currentChannel.url;

                return ListTile(
                  selected: isPlaying,
                  selectedTileColor: Colors.blueGrey[900],
                  leading: ch.logo.isNotEmpty
                      ? Image.network(ch.logo, width: 40, errorBuilder: (_, __, ___) => const Icon(Icons.tv))
                      : const Icon(Icons.tv),
                  title: Text(ch.name),
                  onTap: () => _switchTo(ch),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Info Page
class InfoPage extends StatelessWidget {
  final ServerConfig? config;

  const InfoPage({super.key, this.config});

  Future<void> _launchUrl(String url) async {
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
            '${config?.name ?? appName}  •  v${config?.version ?? '1.0.0'}',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),

          const Text('What’s New', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(config?.updateDescription ?? 'Latest improvements and fixes'),

          const SizedBox(height: 32),
          if (config?.apkDownload.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: () => _launchUrl(config!.apkDownload),
              icon: const Icon(Icons.android),
              label: const Text('Download APK'),
            ),
          const SizedBox(height: 12),
          if (config?.webDownload.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: () => _launchUrl(config!.webDownload),
              icon: const Icon(Icons.web),
              label: const Text('Web Version'),
            ),

          const SizedBox(height: 40),
          const Text('Disclaimer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(config?.disclaimer ?? 'All content belongs to their respective owners. We only provide links.'),

          const SizedBox(height: 40),
          const Text('Contact Us', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _launchUrl(config?.telegramUser ?? ''),
            icon: const Icon(Icons.telegram),
            label: const Text('Telegram Personal'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _launchUrl(config?.telegramGroup ?? ''),
            icon: const Icon(Icons.group),
            label: const Text('Telegram Group'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _launchUrl(config?.website ?? ''),
            icon: const Icon(Icons.language),
            label: const Text('Website'),
          ),

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
