import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/bus_service.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';
import '../../models/models.dart';
import '../../widgets/bus_card.dart';
import 'map_screen.dart';

class BusListScreen extends StatefulWidget {
  const BusListScreen({super.key});

  @override
  State<BusListScreen> createState() => _BusListScreenState();
}

class _BusListScreenState extends State<BusListScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _filterStatus = 'all';
  bool _browseAllHostels = false;
  bool _loadingAllHostels = false;
  List<BusModel> _allHostelBuses = [];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bus = context.watch<BusService>();
    final auth = context.watch<AuthService>();
    final hostel = auth.currentUser?.hostelId ?? '';
    var buses = _browseAllHostels
        ? _allHostelBuses
        : bus.getBusesByHostel(hostel);

    if (_searchQuery.isNotEmpty) {
      buses = buses
          .where(
            (b) =>
                b.busNumber.toString().contains(_searchQuery) ||
                (_browseAllHostels &&
                    b.assignedHostel.toLowerCase().contains(
                      _searchQuery.toLowerCase(),
                    )) ||
                (b.driver?.name.toLowerCase().contains(
                      _searchQuery.toLowerCase(),
                    ) ??
                    false),
          )
          .toList();
    }
    if (_filterStatus != 'all') {
      buses = buses.where((b) => b.status == _filterStatus).toList();
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text(_browseAllHostels ? 'Today • All Hostels' : 'My Buses'),
        actions: [
          IconButton(
            tooltip: _browseAllHostels
                ? 'Show my hostel buses'
                : 'Browse all hostels',
            icon: Icon(_browseAllHostels ? Icons.home : Icons.travel_explore),
            onPressed: _loadingAllHostels
                ? null
                : () => _toggleAllHostels(context),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            onSelected: (v) => setState(() => _filterStatus = v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'all', child: Text('All Buses')),
              const PopupMenuItem(value: 'running', child: Text('Running')),
              const PopupMenuItem(value: 'idle', child: Text('Idle')),
              const PopupMenuItem(
                value: 'maintenance',
                child: Text('Maintenance'),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              onSubmitted: (value) {
                final query = value.trim().toLowerCase();
                const locations = [
                  'BH1',
                  'BH2',
                  'BH3',
                  'BH4',
                  'GH1',
                  'GH2',
                  'Block 8',
                  'MBSE',
                ];
                String? location;
                for (final item in locations) {
                  if (item.toLowerCase() == query) location = item;
                }
                if (location != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MapScreen(initialStop: location),
                    ),
                  );
                }
              },
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: _browseAllHostels
                    ? 'Search bus, driver, or hostel...'
                    : 'Search by bus number or driver...',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                prefixIcon: const Icon(Icons.search, color: Colors.white),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.2),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
      body: _loadingAllHostels
          ? const Center(child: CircularProgressIndicator())
          : bus.isLoading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    bus.isWaking
                        ? 'Server is waking up, please wait...'
                        : 'Loading buses...',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : bus.error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 44, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text(
                      bus.error!.replaceFirst('Exception: ', ''),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => context.read<BusService>().loadBuses(
                        context.read<ApiService>(),
                        hostel: auth.currentUser?.hostelId,
                        token: auth.currentUser?.token,
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : buses.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.search_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text(
                    _searchQuery.isNotEmpty
                        ? 'No buses found for "$_searchQuery"'
                        : 'No buses available',
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: buses.length + (_browseAllHostels ? 1 : 0),
              itemBuilder: (_, i) {
                if (_browseAllHostels && i == 0) {
                  const stops = [
                    'BH1',
                    'BH2',
                    'BH3',
                    'BH4',
                    'GH1',
                    'GH2',
                    'Block 8',
                    'MBSE',
                  ];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: stops
                          .map(
                            (stop) => ActionChip(
                              avatar: const Icon(Icons.place, size: 16),
                              label: Text(stop),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => MapScreen(initialStop: stop),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  );
                }
                final busIndex = i - (_browseAllHostels ? 1 : 0);
                final item = buses[busIndex];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: BusCard(
                    bus: item,
                    compact: false,
                    showDetails: true,
                    onStartRoute: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MapScreen(selectedBus: item),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _toggleAllHostels(BuildContext context) async {
    if (_browseAllHostels) {
      setState(() => _browseAllHostels = false);
      return;
    }
    final token = context.read<AuthService>().currentUser?.token;
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    if (token == null || token.isEmpty) return;
    setState(() => _loadingAllHostels = true);
    try {
      final data = await api.getTodayScheduledBuses(token: token);
      if (!mounted) return;
      setState(() {
        _allHostelBuses = data
            .map((item) => BusModel.fromJson(item as Map<String, dynamic>))
            .toList();
        _browseAllHostels = true;
      });
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not load today’s buses: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingAllHostels = false);
    }
  }
}
