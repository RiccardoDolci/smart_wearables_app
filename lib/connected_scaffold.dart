import 'package:flutter/material.dart';
import 'package:smart_wearables_app/connection/ble_protocol.dart';
import 'package:smart_wearables_app/pages/live_page.dart';
import 'package:smart_wearables_app/pages/storico_page.dart';
import 'package:smart_wearables_app/storage/history_store.dart';

/// Shown after a successful connection. Holds the two pages (Live + Storico) in
/// an IndexedStack so both keep their state, and drives the board's L/H mode
/// from the selected tab (ble_protocol.md §4: L and H are mutually exclusive).
class ConnectedScaffold extends StatefulWidget {
  const ConnectedScaffold({super.key, required this.protocol});
  final BleProtocol protocol;

  @override
  State<ConnectedScaffold> createState() => _ConnectedScaffoldState();
}

class _ConnectedScaffoldState extends State<ConnectedScaffold> {
  int _index = 0;
  final HistoryStore _store = HistoryStore();
  bool _storeLoaded = false;

  // Notifies the Live page to reset its IR buffer when we re-enter Live.
  final ValueNotifier<int> _liveResetTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() => _storeLoaded = true);
    });
    // Live is the default tab -> start live streaming. Delay so it lands
    // after the connect-time T command (set clock before streaming).
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) widget.protocol.sendLive();
    });
  }

  void _onTabSelected(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    if (i == 0) {
      // Returning to Live: restart stream + reset stale IR waveform.
      _liveResetTick.value++;
      widget.protocol.sendLive();
    } else {
      // Storico: H stops live and pulls the history dump.
      widget.protocol.sendHistory();
    }
  }

  @override
  void dispose() {
    _liveResetTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(_index == 0 ? 'Live' : 'Storico'),
      ),
      body: !_storeLoaded
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _index,
              children: [
                LivePage(
                  protocol: widget.protocol,
                  resetTick: _liveResetTick,
                ),
                StoricoPage(
                  protocol: widget.protocol,
                  store: _store,
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTabSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            label: 'Storico',
          ),
        ],
      ),
    );
  }
}
