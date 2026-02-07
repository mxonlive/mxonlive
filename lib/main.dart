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
const String configUrl = 'https://raw.githubusercontent.com/mxonlive/mxonlive/main/config.json';
const String defaultM3uUrl = 'https://private-zone-by-xfireflix.pages.dev/playlist-isp-bdix.m3u';

const String cacheConfigKey = 'mxonlive_cached_config';
const String cachePlaylistKey = 'mxonlive_cached_playlist';

const Duration requestTimeout = Duration(seconds: 25);

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
        'updates': {
          'title': updateTitle,
          'description': updateDescription,
        },
        'downloads': {
          'apk': apkDownload,
          'web': webDownload,
        },
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
//  SERVICES
// ──────────────────────────────────────────────

class ConfigService {
  static Future<ServerConfig> loadConfig() async {
    try {
      final response = await http.get(Uri.parse(configUrl)).timeout(requestTimeout);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final config = ServerConfig.fromJson(json);
        await _saveToCache(config);
        return config;
      }
    } catch (_) {
      // silent fail → try cache
    }

    final cached = await _getFromCache();
    if (cached != null) return cached;

    // ultimate fallback
    return ServerConfig(
      name: appName,
      version: '1.0.0',
      welcomeMessage: 'Welcome to mxonlive (offline mode)',
      notification: '',
      m3uUrl: defaultM3uUrl,
      updateTitle: "Offline Mode",
      updateDescription: "Using default settings",
      apkDownload: '',
      webDownload: '',
      disclaimer: 'Offline fallback active',
      telegramUser: '',
      telegramGroup: '',
      website: '',
      welcomeEnabled: true,
      notificationEnabled: false,
    );
  }

  static Future<void> _saveToCache(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheConfigKey, jsonEncode(config.toJson()));
  }

  static Future<ServerConfig?> _getFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(cacheConfigKey);
    if (raw == null) return null;
    try {
      return ServerConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

class PlaylistService {
  static Future<List<Channel>> loadAndParsePlaylist(String url) async {
    String content;

    try {
      final res = await http.get(Uri.parse(url)).timeout(requestTimeout);
      if (res.statusCode == 200) {
        content = res.body;
        await _cachePlaylist(content);
      } else {
        content = await _getCachedPlaylist() ?? '';
      }
    } catch (_) {
      content = await _getCachedPlaylist() ?? '';
    }

    if (content.isEmpty) return [];

    return _parseM3u(content);
  }

  static List<Channel> _parseM3u(String text) {
    final lines = text.split('\n');
    final List<Channel> channels = [];

    String? name;
    String? logo;
    String? group;
    String? url;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('#EXTINF:')) {
        // extract name (after last comma)
        final commaSplit = trimmed.split(',');
        name = commaSplit.length > 1 ? commaSplit.last.trim() : 'Unknown';

        // extract attributes with regex
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
            groupTitle: group ?? 'Others',
            url: url,
          ));
        }

        // reset
        name = null;
        logo = null;
        group = null;
        url = null;
      }
    }

    return channels;
  }

  static Future<void> _cachePlaylist(String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cachePlaylistKey, content);
  }

  static Future<String?> _getCachedPlaylist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(cachePlaylistKey);
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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ServerConfig? config;
  List<Channel> channels = [];
  List<Channel> filtered = [];
  bool loading = true;
  String? errorMsg;

  final searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
    searchCtrl.addListener(_filter);
  }

  Future<void> _loadData() async {
    setState(() {
      loading = true;
      errorMsg = null;
    });

    try {
      final cfg = await ConfigService.loadConfig();
      final chList = await PlaylistService.loadAndParsePlaylist(cfg.m3uUrl);

      setState(() {
        config = cfg;
        channels = chList;
        filtered = chList;
        loading = false;
      });
    } catch (e) {
      setState(() {
        errorMsg = e.toString();
        loading = false;
      });
    }
  }

  void _filter() {
    final q = searchCtrl.text.trim().toLowerCase();
    setState(() {
      filtered = channels.where((c) {
        return c.name.toLowerCase().contains(q) ||
            c.groupTitle.toLowerCase().contains(q);
      }).toList();
    });
  }

  @override
  void dispose() {
    searchCtrl.dispose();
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
              MaterialPageRoute(builder: (_) => InfoScreen(config: config)),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: loading
            ? _shimmerGrid()
            : errorMsg != null
                ? _errorScreen()
                : _mainContent(),
      ),
    );
  }

  Widget _shimmerGrid() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[850]!,
      highlightColor: Colors.grey[700]!,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 0.75,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: 20,
        itemBuilder: (_, __) => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _errorScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 80, color: Colors.redAccent),
            const SizedBox(height: 24),
            const Text('Failed to load content', style: TextStyle(fontSize: 22)),
            const SizedBox(height: 12),
            Text(errorMsg ?? 'Unknown error', textAlign: TextAlign.center),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mainContent() {
    return CustomScrollView(
      slivers: [
        // Welcome
        if (config?.welcomeEnabled == true)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                config?.welcomeMessage ?? 'Welcome!',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // Notification banner
        if (config?.notificationEnabled == true && (config?.notification ?? '').isNotEmpty)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.amber[900],
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                config!.notification,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // Search
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: searchCtrl,
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

        // Grid
        if (filtered.isEmpty)
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
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final ch = filtered[i];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        ctx,
                        MaterialPageRoute(
                          builder: (_) => PlayerScreen(
                            initial: ch,
                            group: channels.where((c) => c.groupTitle == ch.groupTitle).toList(),
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
                                ? Image.network(ch.logo, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.tv, size: 50))
                                : const Icon(Icons.tv, size: 50),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text(
                              ch.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                childCount: filtered.length,
              ),
            ),
          ),
      ],
    );
  }
}

class PlayerScreen extends StatefulWidget {
  final Channel initial;
  final List<Channel> group;

  const PlayerScreen({super.key, required this.initial, required this.group});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late VideoPlayerController videoCtrl;
  ChewieController? chewieCtrl;
  late Channel current;
  bool initializing = true;
  String? playerError;

  @override
  void initState() {
    super.initState();
    current = widget.initial;
    _startPlayer();
  }

  Future<void> _startPlayer() async {
    setState(() {
      initializing = true;
      playerError = null;
    });

    try {
      videoCtrl = VideoPlayerController.networkUrl(Uri.parse(current.url));
      await videoCtrl.initialize();

      chewieCtrl = ChewieController(
        videoPlayerController: videoCtrl,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: true,
      );

      setState(() => initializing = false);
    } catch (e) {
      setState(() {
        playerError = e.toString();
        initializing = false;
      });
    }
  }

  void _switchChannel(Channel ch) {
    if (ch.url == current.url) return;

    chewieCtrl?.pause();
    chewieCtrl?.dispose();
    videoCtrl.dispose();

    current = ch;
    _startPlayer();
  }

  @override
  void dispose() {
    chewieCtrl?.dispose();
    videoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(current.name)),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: initializing
                ? const Center(child: CircularProgressIndicator())
                : playerError != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Player error: $playerError', textAlign: TextAlign.center),
                            const SizedBox(height: 20),
                            ElevatedButton(
                              onPressed: _startPlayer,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : Chewie(controller: chewieCtrl!),
          ),

          Expanded(
            flex: 3,
            child: ListView.builder(
              itemCount: widget.group.length,
              itemBuilder: (ctx, i) {
                final ch = widget.group[i];
                final active = ch.url == current.url;

                return ListTile(
                  selected: active,
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

class InfoScreen extends StatelessWidget {
  final ServerConfig? config;

  const InfoScreen({super.key, this.config});

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
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${config?.name ?? appName} • v${config?.version ?? '1.0.0'}',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),

          const Text('What’s New', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(config?.updateDescription ?? 'Latest bug fixes & improvements'),

          const SizedBox(height: 32),
          if (config?.apkDownload.isNotEmpty == true) ...[
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.apkDownload),
              icon: const Icon(Icons.android),
              label: const Text('Download APK'),
            ),
            const SizedBox(height: 12),
          ],
          if (config?.webDownload.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.webDownload),
              icon: const Icon(Icons.web),
              label: const Text('Web Version'),
            ),

          const SizedBox(height: 40),
          const Text('Disclaimer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(config?.disclaimer ?? 'All streams are property of their respective owners.'),

          const SizedBox(height: 40),
          const Text('Contact', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          if (config?.telegramUser.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.telegramUser),
              icon: const Icon(Icons.telegram),
              label: const Text('Telegram Personal'),
            ),
          const SizedBox(height: 12),
          if (config?.telegramGroup.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.telegramGroup),
              icon: const Icon(Icons.group),
              label: const Text('Telegram Group'),
            ),
          const SizedBox(height: 12),
          if (config?.website.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: () => _openLink(config!.website),
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
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
