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
      name: json['app']['name'] ?? appName,
      version: json['app']['version'] ?? '1.0.0',
      welcomeMessage: json['app']['welcome_message'] ?? 'Welcome to mxonlive',
      notification: json['app']['notification'] ?? '',
      m3uUrl: json['app']['m3u_url'] ?? defaultM3uUrl,
      updateTitle: json['updates']['title'] ?? "What's New",
      updateDescription: json['updates']['description'] ?? '',
      apkDownload: json['downloads']['apk'] ?? '',
      webDownload: json['downloads']['web'] ?? '',
      disclaimer: json['legal']['disclaimer'] ?? '',
      creditsPlatform: json['credits']['platform'] ?? '',
      telegramUser: json['contact']['telegram_user'] ?? '',
      telegramGroup: json['contact']['telegram_group'] ?? '',
      website: json['contact']['website'] ?? '',
      welcomeEnabled: json['features']['welcome_enabled'] ?? true,
      notificationEnabled: json['features']['notification_enabled'] ?? true,
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
        final json = jsonDecode(response.body);
        final config = ServerConfig.fromJson(json);
        _cacheConfig(config);
        return config;
      } else {
        throw Exception('Failed to load config: ${response.statusCode}');
      }
    } catch (e) {
      final cached = await _getCachedConfig();
      if (cached != null) return cached;
      throw Exception('No internet and no cache: $e');
    }
  }

  static Future<String> fetchPlaylist(String m3uUrl) async {
    try {
      final response = await http.get(Uri.parse(m3uUrl)).timeout(timeoutDuration);
      if (response.statusCode == 200) {
        _cachePlaylist(response.body);
        return response.body;
      } else {
        throw Exception('Failed to load playlist: ${response.statusCode}');
      }
    } catch (e) {
      final cached = await _getCachedPlaylist();
      if (cached != null) return cached;
      throw Exception('No internet and no cache: $e');
    }
  }

  static Future<void> _cacheConfig(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheConfigKey, jsonEncode(config.toJson()));
  }

  static Future<ServerConfig?> _getCachedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(cacheConfigKey);
    if (jsonStr != null) {
      return ServerConfig.fromJson(jsonDecode(jsonStr));
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
    String? name, logo, groupTitle, url;

    for (var line in lines) {
      line = line.trim();
      if (line.startsWith('#EXTINF:')) {
        final parts = line.substring(8).split(',');
        name = parts.length > 1 ? parts[1] : 'Unknown';
        logo = _extractAttribute(line, 'tvg-logo');
        groupTitle = _extractAttribute(line, 'group-title') ?? 'Uncategorized';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        url = line;
        if (name != null && url != null) {
          channels.add(Channel(name: name, logo: logo ?? '', groupTitle: groupTitle, url: url));
          name = url = logo = groupTitle = null;
        }
      }
    }
    return channels;
  }

  static String? _extractAttribute(String line, String attr) {
    final regex = RegExp('$attr="([^"]*)"');
    final match = regex.firstMatch(line);
    return match?.group(1);
  }
}

// UI Widgets
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      theme: ThemeData.dark(),  // Dark mode support
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
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
  String errorMessage = '';
  TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
    searchController.addListener(_filterChannels);
  }

  Future<void> _loadData() async {
    setState(() => isLoading = true);
    try {
      config = await ApiService.fetchConfig();
      final playlist = await ApiService.fetchPlaylist(config!.m3uUrl);
      channels = PlaylistService.parseM3u(playlist);
      filteredChannels = channels;
      errorMessage = '';
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      setState(() => isLoading = false);
    }
  }

  void _filterChannels() {
    final query = searchController.text.toLowerCase();
    setState(() {
      filteredChannels = channels.where((ch) {
        return ch.name.toLowerCase().contains(query) || ch.groupTitle.toLowerCase().contains(query);
      }).toList();
    });
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
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InfoPage(config: config))),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: isLoading
            ? _buildSkeleton()
            : errorMessage.isNotEmpty
                ? _buildError(errorMessage)
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        if (config != null && config!.welcomeEnabled) ...[
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text(config!.welcomeMessage, style: const TextStyle(fontSize: 18)),
                          ),
                        ],
                        if (config != null && config!.notificationEnabled && config!.notification.isNotEmpty) ...[
                          _buildNotificationCapsule(config!.notification),
                        ],
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: TextField(
                            controller: searchController,
                            decoration: const InputDecoration(
                              labelText: 'Search channels',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        filteredChannels.isEmpty
                            ? const Center(child: Text('No channels found'))
                            : GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  childAspectRatio: 1.5,
                                ),
                                itemCount: filteredChannels.length,
                                itemBuilder: (ctx, idx) {
                                  final ch = filteredChannels[idx];
                                  return GestureDetector(
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PlayerPage(
                                          channel: ch,
                                          groupChannels: channels.where((c) => c.groupTitle == ch.groupTitle).toList(),
                                        ),
                                      ),
                                    ),
                                    child: Card(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          ch.logo.isNotEmpty
                                              ? Image.network(ch.logo, height: 50, errorBuilder: (_, __, ___) => const Icon(Icons.tv))
                                              : const Icon(Icons.tv),
                                          Text(ch.name, textAlign: TextAlign.center),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _buildSkeleton() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 1.5),
        itemCount: 20,
        itemBuilder: (_, __) => Container(color: Colors.white),
      ),
    );
  }

  Widget _buildError(String msg) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(msg),
          ElevatedButton(onPressed: _loadData, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildNotificationCapsule(String text) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.blue[800], borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

class PlayerPage extends StatefulWidget {
  final Channel channel;
  final List<Channel> groupChannels;

  const PlayerPage({super.key, required this.channel, required this.groupChannels});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _videoController;
  ChewieController? _chewieController;
  bool isLoading = true;
  String errorMessage = '';
  Channel? currentChannel;

  @override
  void initState() {
    super.initState();
    currentChannel = widget.channel;
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    setState(() => isLoading = true);
    try {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(currentChannel!.url));
      await _videoController.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _videoController,
        autoPlay: true,
        looping: false,
        fullScreenByDefault: false,
        errorBuilder: (context, error) => Center(child: Text('Error: $error')),
      );
      errorMessage = '';
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      setState(() => isLoading = false);
    }
  }

  void _switchChannel(Channel newChannel) {
    if (currentChannel == newChannel) return;
    _chewieController?.dispose();
    _videoController.dispose();
    currentChannel = newChannel;
    _initPlayer();
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        return Scaffold(
          appBar: AppBar(title: Text(currentChannel!.name)),
          body: Column(
            children: [
              Expanded(
                flex: orientation == Orientation.portrait ? 3 : 6,
                child: isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : errorMessage.isNotEmpty
                        ? _buildError(errorMessage)
                        : Chewie(controller: _chewieController!),
              ),
              Expanded(
                flex: orientation == Orientation.portrait ? 2 : 1,
                child: ListView.builder(
                  itemCount: widget.groupChannels.length,
                  itemBuilder: (ctx, idx) {
                    final ch = widget.groupChannels[idx];
                    return ListTile(
                      title: Text(ch.name),
                      leading: ch.logo.isNotEmpty ? Image.network(ch.logo, width: 30) : const Icon(Icons.tv),
                      selected: ch == currentChannel,
                      onTap: () => _switchChannel(ch),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildError(String msg) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(msg),
          ElevatedButton(onPressed: _initPlayer, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class InfoPage extends StatelessWidget {
  final ServerConfig? config;

  const InfoPage({super.key, this.config});

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      // Handle error
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Info')),
      body: config == null
          ? const Center(child: Text('No config loaded'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('${config!.name} v${config!.version}', style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 16),
                Text(config!.updateTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(config!.updateDescription),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: () => _launchUrl(config!.apkDownload), child: const Text('Download APK')),
                ElevatedButton(onPressed: () => _launchUrl(config!.webDownload), child: const Text('Open Web')),
                const SizedBox(height: 16),
                Text('Disclaimer: ${config!.disclaimer}'),
                const SizedBox(height: 16),
                Text('Credits: ${config!.creditsPlatform}'),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: () => _launchUrl(config!.telegramUser), child: const Text('Telegram Personal')),
                ElevatedButton(onPressed: () => _launchUrl(config!.telegramGroup), child: const Text('Telegram Group')),
                ElevatedButton(onPressed: () => _launchUrl(config!.website), child: const Text('Website')),
                const SizedBox(height: 32),
                const Text('Web Developer: Sultan Muhammad A\'rabi', textAlign: TextAlign.center),
              ],
            ),
    );
  }
}

// Error Handling Helpers
void showSnackbar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

void showErrorDialog(BuildContext context, String title, String content) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(title: Text(title), content: Text(content), actions: [TextButton(onPressed: () => Navigator.pop(_), child: const Text('OK'))]),
  );
}
