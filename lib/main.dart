import 'dart:async';
import 'dart:convert';
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

// --- 🔥 CONFIGURATION 🔥 ---
const String configJsonUrl = "https://raw.githubusercontent.com/mxonlive/mxonlive.github.io/refs/heads/main/live/mxonlive_app_5.json"; 

const String appName = "mxonlive";
const Map<String, String> appHeaders = {
  "User-Agent": "mxonlive/5.0 (Android)",
};

// --- CACHE ---
final customCacheManager = fcm.CacheManager(
  fcm.Config(
    'mxonlive_cache', 
    stalePeriod: const Duration(days: 7), 
    maxNrOfCacheObjects: 500, 
    repo: fcm.JsonCacheInfoRepository(databaseName: 'mxonlive_cache'),
    fileService: fcm.HttpFileService(),
  ),
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  
  // Fullscreen UI
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Color(0xFF0F0F0F),
    statusBarIconBrightness: Brightness.light,
  ));
  
  runApp(const MxOnLiveApp());
}

// --- MODELS ---
class Channel {
  final String name;
  final String logo;
  final String url;
  final String group;
  final Map<String, String> headers;

  Channel({required this.name, required this.logo, required this.url, required this.group, this.headers = const {}});
}

// --- APP ROOT ---
class MxOnLiveApp extends StatelessWidget {
  const MxOnLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        primaryColor: const Color(0xFFFF3B30), // Red Theme
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

// --- SPLASH & CONFIG LOADER ---
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _fetchConfig();
  }

  Future<void> _fetchConfig() async {
    try {
      final response = await http.get(Uri.parse(configJsonUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final playlistUrl = data['playlist_url'] ?? "";
        final notice = data['notice_text'] ?? "Welcome to mxonlive";
        
        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomePage(playlistUrl: playlistUrl, notice: notice)));
        }
      } else {
        throw Exception("Config Error");
      }
    } catch (e) {
      // Retry
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _fetchConfig();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF1E1E1E), boxShadow: [BoxShadow(color: Colors.red.withOpacity(0.3), blurRadius: 40)]),
              child: ClipRRect(borderRadius: BorderRadius.circular(100), child: Image.asset('assets/logo.png', width: 100, height: 100)),
            ),
            const SizedBox(height: 30),
            const SpinKitThreeBounce(color: Colors.redAccent, size: 30),
            const SizedBox(height: 10),
            const Text("Initializing Stream Engine...", style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// --- HOME PAGE ---
class HomePage extends StatefulWidget {
  final String playlistUrl;
  final String notice;
  const HomePage({super.key, required this.playlistUrl, required this.notice});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Channel> allChannels = [];
  List<Channel> filteredChannels = [];
  List<String> groups = ["All"];
  String selectedGroup = "All";
  bool isLoading = true;
  TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    setState(() { isLoading = true; });
    try {
      final response = await http.get(Uri.parse(widget.playlistUrl), headers: appHeaders).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        _parseAdvancedM3U(response.body);
      } else {
        throw Exception("Playlist Failed");
      }
    } catch (e) {
      setState(() { isLoading = false; });
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  // 🔥 ADVANCED M3U PARSER (THE FIX) 🔥
  void _parseAdvancedM3U(String content) {
    List<String> lines = const LineSplitter().convert(content);
    List<Channel> channels = [];
    Set<String> uniqueGroups = {};
    
    String? name; String? logo; String? group; 
    Map<String, String> currentHeaders = {};

    for (String line in lines) {
      line = line.trim(); if (line.isEmpty) continue;
      
      if (line.startsWith("#EXTINF:")) {
        // Name Parsing
        final nameMatch = RegExp(r',(.*)').firstMatch(line); 
        name = nameMatch?.group(1)?.trim();
        if (name == null || name.isEmpty) { final tvgName = RegExp(r'tvg-name="([^"]*)"').firstMatch(line); name = tvgName?.group(1); }
        name ??= "Channel ${channels.length + 1}";

        // Logo Parsing
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line); 
        logo = logoMatch?.group(1) ?? "";
        
        // Group Parsing
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line); 
        group = groupMatch?.group(1) ?? "Others";
        uniqueGroups.add(group);

      } else if (line.startsWith("#EXTVLCOPT:") || line.startsWith("#EXTHTTP:") || line.startsWith("#KODIPROP:")) {
        // 🔥 HEADER PARSING (Fixes 403 Errors) 🔥
        String raw = line.substring(line.indexOf(":") + 1).trim();
        if (raw.toLowerCase().contains("user-agent=")) {
          currentHeaders['User-Agent'] = raw.split('=')[1].trim();
        } else if (raw.toLowerCase().contains("referrer=") || raw.toLowerCase().contains("referer=")) {
          currentHeaders['Referer'] = raw.split('=')[1].trim();
        } else if (raw.toLowerCase().contains("cookie=")) {
          currentHeaders['Cookie'] = raw.substring(7).trim();
        }
      } else if (!line.startsWith("#")) {
        // URL Line
        if (name != null) {
          // If URL has '|', it contains headers (Kodi style)
          String finalUrl = line;
          if (line.contains("|")) {
            final parts = line.split("|");
            finalUrl = parts[0];
            final headerPart = parts[1];
            // Simple logic for pipe headers
            if (headerPart.toLowerCase().contains("user-agent=")) {
               currentHeaders['User-Agent'] = headerPart.split('=')[1].trim();
            }
          }

          if (!currentHeaders.containsKey('User-Agent')) currentHeaders['User-Agent'] = appHeaders['User-Agent']!;
          
          channels.add(Channel(name: name, logo: logo ?? "", url: finalUrl, group: group ?? "Others", headers: Map.from(currentHeaders)));
          name = null; currentHeaders = {}; 
        }
      }
    }

    List<String> sortedGroups = uniqueGroups.toList()..sort();
    
    setState(() { 
      allChannels = channels; 
      filteredChannels = channels;
      groups = ["All", ...sortedGroups];
      isLoading = false; 
    });
  }

  void _filterData() {
    String query = searchController.text.toLowerCase();
    setState(() {
      filteredChannels = allChannels.where((c) {
        bool matchesSearch = c.name.toLowerCase().contains(query);
        bool matchesGroup = selectedGroup == "All" || c.group == selectedGroup;
        return matchesSearch && matchesGroup;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName, style: TextStyle(letterSpacing: 1.2)),
        leading: Padding(padding: const EdgeInsets.all(10.0), child: Image.asset('assets/logo.png', errorBuilder: (c,o,s)=>const Icon(Icons.tv, color: Colors.red))),
        actions: [IconButton(icon: const Icon(Icons.refresh, color: Colors.white70), onPressed: _loadPlaylist)],
      ),
      body: Column(children: [
        // NOTICE
        if(widget.notice.isNotEmpty)
          Container(height: 35, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: const Color(0xFF252525), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.redAccent.withOpacity(0.3))), child: ClipRRect(borderRadius: BorderRadius.circular(30), child: Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 12), color: Colors.redAccent.withOpacity(0.15), height: double.infinity, child: const Icon(Icons.campaign_rounded, size: 18, color: Colors.redAccent)), Expanded(child: Marquee(text: widget.notice, style: const TextStyle(color: Colors.white), scrollAxis: Axis.horizontal, blankSpace: 20.0, velocity: 40.0))]))),
        
        // SEARCH
        Container(height: 45, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.white10)), child: TextField(controller: searchController, onChanged: (v) => _filterData(), style: const TextStyle(color: Colors.white), cursorColor: Colors.redAccent, decoration: InputDecoration(hintText: "Search Channels...", prefixIcon: const Icon(Icons.search, color: Colors.grey), suffixIcon: searchController.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 18, color: Colors.grey), onPressed: () { searchController.clear(); _filterData(); }) : null, border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 10)))),
        
        const SizedBox(height: 10),

        // GROUP FILTER
        SizedBox(height: 40, child: ListView.builder(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: groups.length, itemBuilder: (ctx, index) {
          final grp = groups[index]; final isSelected = selectedGroup == grp;
          return Padding(padding: const EdgeInsets.only(right: 8), child: GestureDetector(onTap: () { setState(() { selectedGroup = grp; _filterData(); }); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: isSelected ? Colors.redAccent.shade700 : const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(20), border: isSelected ? null : Border.all(color: Colors.white10)), child: Center(child: Text(grp, style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 12))))));
        })),

        const Divider(color: Colors.white10, height: 20),

        // CHANNEL GRID
        Expanded(child: isLoading ? const Center(child: SpinKitFadingCircle(color: Colors.redAccent)) : GridView.builder(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.85, crossAxisSpacing: 10, mainAxisSpacing: 10), itemCount: filteredChannels.length, itemBuilder: (ctx, i) { final ch = filteredChannels[i]; return GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(channel: ch))), child: Container(decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withOpacity(0.05))), child: Column(children: [Expanded(child: Padding(padding: const EdgeInsets.all(8.0), child: ChannelLogo(url: ch.logo))), Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 6), color: Colors.black26, child: Text(ch.name, maxLines: 1, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white70)))]))); }))
      ]),
    );
  }
}

// --- PLAYER SCREEN (WITH HEADER INJECTION) ---
class PlayerScreen extends StatefulWidget { final Channel channel; const PlayerScreen({super.key, required this.channel}); @override State<PlayerScreen> createState() => _PlayerScreenState(); }
class _PlayerScreenState extends State<PlayerScreen> {
  late PodPlayerController _ctrl;
  bool isError = false;

  @override void initState() { super.initState(); _init(); }

  void _init() {
    // 🔥 Inject Headers into Player 🔥
    _ctrl = PodPlayerController(
      playVideoFrom: PlayVideoFrom.network(widget.channel.url, httpHeaders: widget.channel.headers),
      podPlayerConfig: const PodPlayerConfig(autoPlay: true, isLooping: true, wakelockEnabled: true, videoQualityPriority: [720, 1080, 480]),
    )..initialise().then((_) { if(mounted) setState((){}); });

    _ctrl.addListener(() {
      if (_ctrl.videoPlayerValue?.hasError ?? false) {
        if(mounted) setState(() { isError = true; });
        print("Player Error: ${_ctrl.videoPlayerValue?.errorDescription}");
      }
    });
  }

  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.channel.name)),
      body: Center(
        child: isError 
          ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.error, color: Colors.red, size: 50),
              const SizedBox(height: 10),
              const Text("Stream Error", style: TextStyle(color: Colors.white)),
              TextButton(onPressed: (){ setState((){isError=false;}); _init(); }, child: const Text("Retry"))
            ])
          : PodVideoPlayer(controller: _ctrl),
      ),
    );
  }
}

class ChannelLogo extends StatelessWidget { final String url; const ChannelLogo({super.key, required this.url}); @override Widget build(BuildContext context) { return CachedNetworkImage(imageUrl: url, cacheManager: customCacheManager, errorWidget: (c,u,e)=>Image.asset('assets/logo.png')); }}
