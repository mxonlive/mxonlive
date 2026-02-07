// mxonlive - A server-driven Flutter IPTV Live TV application.
// This file contains the entire application logic in a single file due to repository constraints.
// All code is null-safe, uses async/await, and follows clean architecture principles within the file structure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:marquee/marquee.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

// ====================
// Models Section
// ====================

// Channel model for parsed M3U entries.
class Channel {
  final String name;
  final String logo;
  final String group;
  final String url;

  Channel({
    required this.name,
    required this.logo,
    required this.group,
    required this.url,
  });

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      name: json['name'] ?? '',
      logo: json['logo'] ?? '',
      group: json['group'] ?? '',
      url: json['url'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'logo': logo,
      'group': group,
      'url': url,
    };
  }
}

// ====================
// Services Section
// ====================

// ApiService handles fetching, parsing, and caching.
class ApiService {
  static const String serverConfigUrl = 'https://raw.githubusercontent.com/mxonlive/mxonlive.github.io/refs/heads/main/live/mxonlive_config.json'; // Hardcoded server JSON URL.
  static const String configCacheKey = 'config_json';
  static const String playlistCacheKey = 'playlist_channels';

  // Fetch server config with timeout and error handling.
  static Future<Map<String, dynamic>?> fetchConfig() async {
    try {
      final response = await http.get(Uri.parse(serverConfigUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } on TimeoutException {
      throw 'Timeout loading server configuration.';
    } on SocketException {
      throw 'No internet connection.';
    } catch (e) {
      throw 'Failed to load server configuration: $e';
    }
    return null;
  }

  // Fetch M3U playlist from URL.
  static Future<String?> fetchPlaylist(String m3uUrl) async {
    try {
      final response = await http.get(Uri.parse(m3uUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return response.body;
      }
    } on TimeoutException {
      throw 'Timeout loading playlist.';
    } on SocketException {
      throw 'No internet connection.';
    } catch (e) {
      throw 'Failed to load playlist: $e';
    }
    return null;
  }

  // Parse M3U content into list of channels.
  static List<Channel> parseM3u(String content) {
    final List<Channel> channels = [];
    final lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXTINF:')) {
        final inf = lines[i].substring(8);
        String name = '';
        String logo = '';
        String group = '';
        final parts = inf.split(',');
        if (parts.length > 1) {
          name = parts.last.trim(); // Fallback name after comma.
        }
        final attrRegex = RegExp(r'(\w+-\w+)="([^"]*)"');
        final matches = attrRegex.allMatches(inf);
        for (final match in matches) {
          final key = match.group(1);
          final value = match.group(2);
          if (key == 'tvg-name' && value != null && value.isNotEmpty) {
            name = value;
          } else if (key == 'tvg-logo') {
            logo = value ?? '';
          } else if (key == 'group-title') {
            group = value ?? '';
          }
        }
        if (i + 1 < lines.length && !lines[i + 1].startsWith('#') && lines[i + 1].trim().isNotEmpty) {
          final url = lines[i + 1].trim();
          channels.add(Channel(name: name, logo: logo, group: group, url: url));
        }
      }
    }
    if (channels.isEmpty) {
      throw 'Invalid M3U format or empty playlist.';
    }
    return channels;
  }

  // Cache config and playlist.
  static Future<void> cacheData(Map<String, dynamic> config, List<Channel> channels) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(configCacheKey, json.encode(config));
    await prefs.setString(playlistCacheKey, json.encode(channels.map((c) => c.toJson()).toList()));
  }

  // Load cached config.
  static Future<Map<String, dynamic>?> loadCachedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(configCacheKey);
    if (cached != null) {
      return json.decode(cached);
    }
    return null;
  }

  // Load cached channels.
  static Future<List<Channel>?> loadCachedChannels() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(playlistCacheKey);
    if (cached != null) {
      final List<dynamic> jsonList = json.decode(cached);
      return jsonList.map((json) => Channel.fromJson(json)).toList();
    }
    return null;
  }
}

// ====================
// UI Section - Main App
// ====================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    // Handle orientation for mobile.
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mxonlive',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system, // Support dark mode.
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ====================
// Home Page
// ====================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, dynamic>? config;
  List<Channel> channels = [];
  List<Channel> filteredChannels = [];
  bool isLoading = true;
  String errorMessage = '';
  String searchQuery = '';
  final TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadData();
    searchController.addListener(() {
      setState(() {
        searchQuery = searchController.text.toLowerCase();
        filteredChannels = channels.where((c) {
          return c.name.toLowerCase().contains(searchQuery) || c.group.toLowerCase().contains(searchQuery);
        }).toList();
      });
    });
  }

  Future<void> loadData({bool retry = false}) async {
    setState(() {
      isLoading = true;
      errorMessage = '';
    });

    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasInternet = connectivityResult != ConnectivityResult.none;

      Map<String, dynamic>? fetchedConfig;
      if (hasInternet || retry) {
        fetchedConfig = await ApiService.fetchConfig();
      }

      if (fetchedConfig != null) {
        config = fetchedConfig;
        final m3uUrl = config?['app']?['m3u_url'] ?? '';
        if (m3uUrl.isEmpty) {
          throw 'Invalid M3U URL in configuration.';
        }
        final m3uContent = await ApiService.fetchPlaylist(m3uUrl);
        if (m3uContent != null) {
          channels = ApiService.parseM3u(m3uContent);
          await ApiService.cacheData(config!, channels);
        } else {
          channels = (await ApiService.loadCachedChannels()) ?? [];
          if (channels.isEmpty) {
            throw 'Failed to load playlist and no cache available.';
          }
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Using cached playlist.')));
        }
      } else {
        config = await ApiService.loadCachedConfig();
        channels = (await ApiService.loadCachedChannels()) ?? [];
        if (config == null || channels.isEmpty) {
          throw hasInternet ? 'Failed to load configuration and no cache.' : 'No internet. No cache available.';
        }
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Offline mode: Using cached data.')));
      }

      setState(() {
        filteredChannels = channels;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage = e.toString();
      });
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Error'),
          content: Text(errorMessage),
          actions: [TextButton(onPressed: () { Navigator.pop(ctx); loadData(retry: true); }, child: const Text('Retry'))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('mxonlive'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              if (config != null) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => InfoPage(config: config!)));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configuration not loaded.')));
              }
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
              ? Center(child: Text(errorMessage))
              : Column(
                  children: [
                    if (config?['features']?['welcome_enabled'] == true && config?['app']?['welcome_message'] != null)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          config!['app']['welcome_message'],
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (config?['features']?['notification_enabled'] == true && config?['app']?['notification'] != null && config?['app']?['notification'].isNotEmpty)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: SizedBox(
                          height: 20,
                          child: Marquee(
                            text: config!['app']['notification'],
                            style: const TextStyle(fontSize: 14),
                            scrollAxis: Axis.horizontal,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            blankSpace: 20,
                            velocity: 50,
                            pauseAfterRound: const Duration(seconds: 1),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: TextField(
                        controller: searchController,
                        decoration: const InputDecoration(
                          labelText: 'Search channels or groups',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ),
                    Expanded(
                      child: channels.isEmpty
                          ? const Center(child: Text('No channels available.'))
                          : GridView.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                childAspectRatio: 1.0,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                              padding: const EdgeInsets.all(8),
                              itemCount: filteredChannels.length,
                              itemBuilder: (ctx, idx) {
                                final channel = filteredChannels[idx];
                                return GestureDetector(
                                  onTap: () {
                                    final sameGroup = channels.where((c) => c.group == channel.group).toList();
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PlayerPage(initialChannel: channel, sameGroupChannels: sameGroup),
                                      ),
                                    );
                                  },
                                  child: Card(
                                    elevation: 2,
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        CachedNetworkImage(
                                          imageUrl: channel.logo,
                                          height: 50,
                                          width: 50,
                                          placeholder: (context, url) => Shimmer.fromColors(
                                            baseColor: Colors.grey[300]!,
                                            highlightColor: Colors.grey[100]!,
                                            child: Container(width: 50, height: 50, color: Colors.white),
                                          ),
                                          errorWidget: (context, url, error) => Image.asset('assets/logo.png', height: 50, width: 50),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(channel.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }
}

// ====================
// Player Page
// ====================

class PlayerPage extends StatefulWidget {
  final Channel initialChannel;
  final List<Channel> sameGroupChannels;

  const PlayerPage({super.key, required this.initialChannel, required this.sameGroupChannels});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _videoController;
  late ChewieController _chewieController;
  Channel? currentChannel;
  String playerError = '';

  @override
  void initState() {
    super.initState();
    currentChannel = widget.initialChannel;
    _initPlayer();
  }

  void _initPlayer() {
    _videoController = VideoPlayerController.networkUrl(Uri.parse(currentChannel!.url));
    _chewieController = ChewieController(
      videoPlayerController: _videoController,
      autoPlay: true,
      looping: false,
      fullScreenByDefault: false,
      allowFullScreen: true,
      errorBuilder: (context, errorMessage) {
        setState(() { playerError = errorMessage; });
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Playback error: $errorMessage'),
              ElevatedButton(onPressed: _retryPlayback, child: const Text('Retry')),
            ],
          ),
        );
      },
      showControlsOnInitialize: true,
      deviceOrientationsAfterFullScreen: [DeviceOrientation.portraitUp],
    );
    _videoController.initialize().then((_) => setState(() {}));
  }

  void _switchChannel(Channel newChannel) {
    setState(() {
      playerError = '';
      currentChannel = newChannel;
    });
    _chewieController.dispose();
    _videoController.dispose();
    _initPlayer();
  }

  void _retryPlayback() {
    _switchChannel(currentChannel!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(currentChannel!.name)),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Chewie(controller: _chewieController),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.sameGroupChannels.length,
              itemBuilder: (ctx, idx) {
                final channel = widget.sameGroupChannels[idx];
                return ListTile(
                  title: Text(channel.name),
                  leading: CachedNetworkImage(
                    imageUrl: channel.logo,
                    width: 40,
                    height: 40,
                    placeholder: (context, url) => Shimmer.fromColors(
                      baseColor: Colors.grey[300]!,
                      highlightColor: Colors.grey[100]!,
                      child: Container(width: 40, height: 40, color: Colors.white),
                    ),
                    errorWidget: (context, url, error) => Image.asset('assets/logo.png', width: 40, height: 40),
                  ),
                  selected: channel.url == currentChannel!.url,
                  onTap: () => _switchChannel(channel),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _videoController.dispose();
    _chewieController.dispose();
    super.dispose();
  }
}

// ====================
// Info Page
// ====================

class InfoPage extends StatelessWidget {
  final Map<String, dynamic> config;

  const InfoPage({super.key, required this.config});

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $url';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Info')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('\( {config['app']['name']} v \){config['app']['version']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('What\'s New', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(config['updates']['description'] ?? ''),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: () => _launchUrl(config['downloads']['apk']), child: const Text('Download APK')),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: () => _launchUrl(config['downloads']['web']), child: const Text('Web Version')),
          const SizedBox(height: 16),
          const Text('Disclaimer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(config['legal']['disclaimer'] ?? ''),
          const SizedBox(height: 16),
          const Text('Credits', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(config['credits']['platform'] ?? ''),
          const SizedBox(height: 16),
          ElevatedButton.icon(onPressed: () => _launchUrl(config['contact']['telegram_user']), icon: const Icon(Icons.telegram), label: const Text('Telegram Personal')),
          const SizedBox(height: 8),
          ElevatedButton.icon(onPressed: () => _launchUrl(config['contact']['telegram_group']), icon: const Icon(Icons.telegram), label: const Text('Telegram Group')),
          const SizedBox(height: 8),
          ElevatedButton.icon(onPressed: () => _launchUrl(config['contact']['website']), icon: const Icon(Icons.web), label: const Text('Website')),
          const SizedBox(height: 32),
          const Text('Web Developer: Sultan Muhammad A\'rabi', textAlign: TextAlign.center, style: TextStyle(fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}
