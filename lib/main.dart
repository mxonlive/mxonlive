import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as fcm; 
import 'package:pod_player/pod_player.dart';
import 'package:marquee/marquee.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

// --- CONFIG ---
const String primaryConfigUrl = "https://raw.githubusercontent.com/mxonlive/mxonlive.github.io/refs/heads/main/live/mxonlive_app_3.json";
const String backupConfigUrl = "https://raw.githubusercontent.com/mhmimxl/mxliveoo/refs/heads/main/config.json"; 
const String contactEmail = "mailto:sultanarabi161@gmail.com";
const String telegramUrl = "https://t.me/mxonlive";
const String appName = "mxonlive";

const Map<String, String> defaultHeaders = {
  "User-Agent": "mxonlive-agent/4.0.0 (Android; Secure)",
};

// --- CACHE ---
final customCacheManager = fcm.CacheManager(
  fcm.Config(
    'mxonlive_ultra_v4', 
    stalePeriod: const Duration(days: 3), 
    maxNrOfCacheObjects: 500, 
    repo: fcm.JsonCacheInfoRepository(databaseName: 'mxonlive_ultra_v4'),
    fileService: fcm.HttpFileService(),
  ),
);

// Firebase Instance
FirebaseAnalytics analytics = FirebaseAnalytics.instance;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  WakelockPlus.enable();
  
  // Initialize Firebase safely
  try {
    await Firebase.initializeApp();
  } catch (e) {
    print("Firebase Init Error: $e");
  }
  
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Color(0xFF0F0F0F),
    statusBarIconBrightness: Brightness.light,
  ));
  
  runApp(const MxOnLiveApp());
}

// --- MODELS ---
class ServerItem {
  final String id;
  final String name;
  final String url;
  ServerItem({required this.id, required this.name, required this.url});
}

class Channel {
  final String name;
  final String logo;
  final String url;
  final String group;
  final Map<String, String> headers;

  Channel({required this.name, required this.logo, required this.url, required this.group, this.headers = const {}});
}

class AppConfig {
  String notice;
  String aboutNotice;
  Map<String, dynamic>? updateData;
  List<ServerItem> servers;

  AppConfig({this.notice = "Welcome", this.aboutNotice = "No info.", this.updateData, this.servers = const []});
}

// --- APP ---
class MxOnLiveApp extends StatelessWidget {
  const MxOnLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      navigatorObservers: [
        FirebaseAnalyticsObserver(analytics: analytics),
      ],
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        primaryColor: const Color(0xFFFF3B30),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF141414),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, fontFamily: 'Sans'),
        ),
        textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

// --- LOGO ---
class ChannelLogo extends StatelessWidget {
  final String url;
  const ChannelLogo({super.key, required this.url});
  @override
  Widget build(BuildContext context) {
    if (url.isEmpty || !url.startsWith('http')) return _fallback();
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: customCacheManager,
      fit: BoxFit.contain,
      placeholder: (context, url) => const Center(child: SpinKitPulse(color: Colors.redAccent, size: 15)),
      errorWidget: (context, url, error) => _fallback(),
    );
  }
  Widget _fallback() => Padding(padding: const EdgeInsets.all(8.0), child: Opacity(opacity: 0.3, child: Image.asset('assets/logo.png', fit: BoxFit.contain)));
}

// --- SPLASH ---
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () {
      if(mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
    });
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF1E1E1E), boxShadow: [BoxShadow(color: Colors.red.withOpacity(0.3), blurRadius: 40)]),
              child: ClipRRect(borderRadius: BorderRadius.circular(100), child: Image.asset('assets/logo.png', width: 100, height: 100)),
            ),
            const SizedBox(height: 30),
            const SpinKitThreeBounce(color: Colors.redAccent, size: 25),
            const SizedBox(height: 10),
            const Text("v4.0.0", style: TextStyle(color: Colors.grey, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// --- HOME ---
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppConfig appConfig = AppConfig();
  ServerItem? selectedServer;
  List<Channel> allChannels = [];
  Map<String, List<Channel>> groupedChannels = {};
  bool isConfigLoading = true;
  bool isPlaylistLoading = false;
  TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    fetchConfig();
    analytics.logEvent(name: 'app_home_loaded');
  }

  void _showMsg(String msg, {bool isError = false}) {
    if(!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg, style: const TextStyle(color: Colors.white)), backgroundColor: isError ? Colors.red.shade900 : Colors.green.shade800, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
  }

  Future<void> fetchConfig() async {
    setState(() { isConfigLoading = true; });
    try { await _fetchFromUrl(primaryConfigUrl); } catch (e) {
      try { await _fetchFromUrl(backupConfigUrl); _showMsg("Connected via Backup"); } catch (e2) { setState(() { isConfigLoading = false; }); _showMsg("Connection Failed", isError: true); }
    }
  }

  Future<void> _fetchFromUrl(String url) async {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) { _parseConfig(jsonDecode(res.body)); } else { throw Exception("HTTP ${res.statusCode}"); }
  }

  void _parseConfig(Map<String, dynamic> data) {
    List<ServerItem> loadedServers = [];
    if (data['servers'] != null) { for (var s in data['servers']) { loadedServers.add(ServerItem(id: s['id'], name: s['name'], url: s['url'])); } }
    setState(() {
      appConfig = AppConfig(notice: data['notice'] ?? "Welcome", aboutNotice: data['about_notice'] ?? "No info.", updateData: data['update_data'], servers: loadedServers);
      if (loadedServers.isNotEmpty) { selectedServer = loadedServers[0]; isConfigLoading = false; loadPlaylist(loadedServers[0].url); } else { isConfigLoading = false; _showMsg("No Servers", isError: true); }
    });
  }

  Future<void> loadPlaylist(String url) async {
    setState(() { isPlaylistLoading = true; searchController.clear(); });
    try {
      final response = await http.get(Uri.parse(url), headers: defaultHeaders).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) { parseM3u(response.body); } else { throw Exception("Failed"); }
    } catch (e) { setState(() { isPlaylistLoading = false; }); _showMsg("Playlist Error", isError: true); }
  }

  void parseM3u(String content) {
    List<String> lines = const LineSplitter().convert(content);
    List<Channel> channels = [];
    String? name; String? logo; String? group; Map<String, String> currentHeaders = {};

    for (String line in lines) {
      line = line.trim(); if (line.isEmpty) continue;
      if (line.startsWith("#EXTINF:")) {
        final nameMatch = RegExp(r',(.*)').firstMatch(line); name = nameMatch?.group(1)?.trim();
        if (name == null || name.isEmpty) { final tvgName = RegExp(r'tvg-name="([^"]*)"').firstMatch(line); name = tvgName?.group(1); }
        name ??= "Channel ${channels.length + 1}";
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line); logo = logoMatch?.group(1) ?? "";
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line); group = groupMatch?.group(1) ?? "Others";
      } else if (line.startsWith("#EXTVLCOPT:") || line.startsWith("#EXTHTTP:") || line.startsWith("#KODIPROP:")) {
        String raw = line.substring(line.indexOf(":") + 1).trim();
        if (raw.toLowerCase().startsWith("http-user-agent=") || raw.toLowerCase().startsWith("user-agent=")) { currentHeaders['User-Agent'] = raw.substring(raw.indexOf("=") + 1).trim(); } 
        else if (raw.toLowerCase().startsWith("http-cookie=")) { currentHeaders['Cookie'] = raw.substring(12).trim(); }
        else if (raw.toLowerCase().startsWith("http-referrer=") || raw.toLowerCase().startsWith("http-referer=")) { currentHeaders['Referer'] = raw.split('=')[1].trim(); }
        else if (raw.toLowerCase().startsWith("http-origin=")) { currentHeaders['Origin'] = raw.split('=')[1].trim(); }
      } else if (!line.startsWith("#")) {
        if (name != null) {
          if (!currentHeaders.containsKey('User-Agent')) currentHeaders['User-Agent'] = defaultHeaders['User-Agent']!;
          channels.add(Channel(name: name, logo: logo ?? "", url: line, group: group ?? "Others", headers: Map.from(currentHeaders)));
          name = null; currentHeaders = {}; 
        }
      }
    }
    setState(() { allChannels = channels; _updateGroupedChannels(channels); isPlaylistLoading = false; });
  }

  void _onSearchChanged(String query) {
    if (query.isEmpty) { setState(() { _updateGroupedChannels(allChannels); }); } else {
      final filtered = allChannels.where((c) => c.name.toLowerCase().contains(query.toLowerCase())).toList();
      setState(() { _updateGroupedChannels(filtered); });
    }
  }

  void _updateGroupedChannels(List<Channel> channels) {
    Map<String, List<Channel>> groups = {};
    for (var ch in channels) { if (!groups.containsKey(ch.group)) groups[ch.group] = []; groups[ch.group]!.add(ch); }
    var sortedKeys = groups.keys.toList()..sort();
    groupedChannels = { for (var k in sortedKeys) k: groups[k]! };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName, style: TextStyle(letterSpacing: 1.2)),
        leading: Padding(padding: const EdgeInsets.all(10.0), child: Image.asset('assets/logo.png', errorBuilder: (c,o,s)=>const Icon(Icons.tv, color: Colors.red))),
        actions: [IconButton(icon: const Icon(Icons.info_outline, color: Colors.white70), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InfoPage(config: appConfig))))],
      ),
      body: RefreshIndicator(
        onRefresh: () async { await fetchConfig(); },
        color: Colors.redAccent, backgroundColor: const Color(0xFF1E1E1E),
        child: isConfigLoading 
            ? const Center(child: SpinKitFadingCircle(color: Colors.redAccent, size: 50))
            : Column(children: [
                  if(appConfig.notice.isNotEmpty) Container(height: 35, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: const Color(0xFF252525), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.redAccent.withOpacity(0.3))), child: ClipRRect(borderRadius: BorderRadius.circular(30), child: Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 12), color: Colors.redAccent.withOpacity(0.15), height: double.infinity, child: const Icon(Icons.campaign_rounded, size: 18, color: Colors.redAccent)), Expanded(child: Marquee(text: appConfig.notice, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500), scrollAxis: Axis.horizontal, blankSpace: 20.0, velocity: 40.0, startPadding: 10.0))]))),
                  Container(height: 45, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.white10)), child: TextField(controller: searchController, onChanged: _onSearchChanged, style: const TextStyle(color: Colors.white), cursorColor: Colors.redAccent, decoration: InputDecoration(hintText: "Search Channels...", hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 14), prefixIcon: const Icon(Icons.search, color: Colors.grey), suffixIcon: searchController.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 18, color: Colors.grey), onPressed: () { searchController.clear(); _onSearchChanged(""); }) : null, border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 10)))),
                  const SizedBox(height: 10),
                  SizedBox(height: 38, child: ListView.builder(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: appConfig.servers.length, itemBuilder: (ctx, index) { final srv = appConfig.servers[index]; final isSelected = selectedServer?.id == srv.id; return Padding(padding: const EdgeInsets.only(right: 10), child: GestureDetector(onTap: () { setState(() => selectedServer = srv); loadPlaylist(srv.url); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: isSelected ? Colors.blueAccent : const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(20), border: isSelected ? null : Border.all(color: Colors.white10)), child: Text(srv.name, style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal))))); })),
                  const Divider(color: Colors.white10, height: 20),
                  Expanded(child: isPlaylistLoading ? const Center(child: SpinKitPulse(color: Colors.blueAccent, size: 40)) : _buildGroupedChannelList()),
                ]),
      ),
    );
  }

  Widget _buildGroupedChannelList() {
    if (groupedChannels.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.sentiment_dissatisfied, size: 50, color: Colors.grey), const SizedBox(height: 10), const Text("No channels found", style: TextStyle(color: Colors.grey)), const SizedBox(height: 20), ElevatedButton.icon(onPressed: () => fetchConfig(), icon: const Icon(Icons.refresh), label: const Text("Retry"), style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white))]));
    return ListView.builder(padding: const EdgeInsets.only(bottom: 20), itemCount: groupedChannels.length, itemBuilder: (context, index) {
        String groupName = groupedChannels.keys.elementAt(index); List<Channel> channels = groupedChannels[groupName]!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 15, 20, 8), child: Row(children: [Container(width: 4, height: 16, color: Colors.redAccent, margin: const EdgeInsets.only(right: 8)), Text(groupName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)), const Spacer(), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)), child: Text("${channels.length}", style: TextStyle(color: Colors.grey.shade400, fontSize: 10)))])),
            GridView.builder(padding: const EdgeInsets.symmetric(horizontal: 16), shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.85, crossAxisSpacing: 10, mainAxisSpacing: 10), itemCount: channels.length, itemBuilder: (ctx, i) { final channel = channels[i]; return GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel, allChannels: allChannels))), child: Container(decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withOpacity(0.05))), child: Column(children: [Expanded(child: Padding(padding: const EdgeInsets.all(8.0), child: ChannelLogo(url: channel.logo))), Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4), decoration: const BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.vertical(bottom: Radius.circular(12))), child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white70), textAlign: TextAlign.center))]))); }),
          ]);
      },
    );
  }
}

// --- PLAYER ---
class PlayerScreen extends StatefulWidget {
  final Channel channel; final List<Channel> allChannels;
  const PlayerScreen({super.key, required this.channel, required this.allChannels});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late PodPlayerController _podController; late List<Channel> relatedChannels; bool isError = false;
  @override
  void initState() {
    super.initState(); WakelockPlus.enable();
    analytics.logEvent(name: 'play_channel', parameters: {'channel_name': widget.channel.name});
    relatedChannels = widget.allChannels.where((c) => c.group == widget.channel.group && c.name != widget.channel.name).toList();
    _initializePlayer();
  }
  Future<void> _initializePlayer() async {
    setState(() { isError = false; });
    try {
      _podController = PodPlayerController(playVideoFrom: PlayVideoFrom.network(widget.channel.url, httpHeaders: widget.channel.headers), podPlayerConfig: const PodPlayerConfig(autoPlay: true, isLooping: true, videoQualityPriority: [720, 1080, 480], wakelockEnabled: true))..initialise().then((_) { if(mounted) setState(() {}); });
      _podController.addListener(() { if (_podController.videoPlayerValue?.hasError ?? false) { if(mounted) setState(() { isError = true; }); } });
    } catch (e) { if(mounted) setState(() { isError = true; }); }
  }
  @override
  void dispose() { try { _podController.dispose(); } catch(e) {} SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]); WakelockPlus.disable(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.channel.name)),
      body: SafeArea(child: Column(children: [
            AspectRatio(aspectRatio: 16 / 9, child: Container(color: Colors.black, child: isError ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.error_outline, color: Colors.red, size: 40), const SizedBox(height: 10), const Text("Stream Offline", style: TextStyle(color: Colors.white)), TextButton(onPressed: _initializePlayer, child: const Text("Retry"))])) : PodVideoPlayer(controller: _podController))),
            Expanded(child: Column(children: [
                  GestureDetector(onTap: () => launchUrl(Uri.parse(telegramUrl), mode: LaunchMode.externalApplication), child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 14), color: const Color(0xFF0088CC), child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.telegram, color: Colors.white), SizedBox(width: 10), Text("JOIN TELEGRAM CHANNEL", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1))]))),
                  const Padding(padding: EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: Text("More Channels", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)))),
                  Expanded(child: ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 10), itemCount: relatedChannels.length, itemBuilder: (ctx, index) { final ch = relatedChannels[index]; return ListTile(contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8), leading: Container(width: 60, height: 40, decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(6)), child: ChannelLogo(url: ch.logo)), title: Text(ch.name, style: const TextStyle(color: Colors.white)), subtitle: Text(ch.group, style: const TextStyle(color: Colors.grey, fontSize: 10)), trailing: const Icon(Icons.play_circle_outline, color: Colors.redAccent), onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PlayerScreen(channel: ch, allChannels: widget.allChannels)))); })),
                ])),
          ])),
    );
  }
}

// --- INFO ---
class InfoPage extends StatelessWidget {
  final AppConfig config; const InfoPage({super.key, required this.config});
  @override
  Widget build(BuildContext context) { final update = config.updateData; final hasUpdate = update != null && update['show'] == true;
    return Scaffold(appBar: AppBar(title: const Text("About & Updates")), body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
            if (hasUpdate) Container(width: double.infinity, margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF007AFF), Color(0xFF00C6FF)]), borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.blueAccent.withOpacity(0.4), blurRadius: 10)]), child: Column(children: [const Icon(Icons.system_update, color: Colors.white, size: 40), const SizedBox(height: 10), Text(update!['version'] ?? "Update Available", style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)), const SizedBox(height: 5), Text(update['note'] ?? "New features are here!", textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)), const SizedBox(height: 15), ElevatedButton(onPressed: () { if (update['download_url'] != null) launchUrl(Uri.parse(update['download_url']), mode: LaunchMode.externalApplication); }, style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.blueAccent), child: const Text("Download Now"))])),
            const SizedBox(height: 20), Text(config.aboutNotice, style: const TextStyle(color: Colors.grey, height: 1.5), textAlign: TextAlign.center), const SizedBox(height: 40), const Divider(color: Colors.white10), ListTile(contentPadding: EdgeInsets.zero, leading: const CircleAvatar(backgroundColor: Colors.redAccent, child: Icon(Icons.person, color: Colors.white)), title: const Text("Developed by Sultan Arabi"), subtitle: const Text("Lettel Developer"), trailing: IconButton(icon: const Icon(Icons.email, color: Colors.white), onPressed: () => launchUrl(Uri.parse(contactEmail)))),
          ])));
  }
}
