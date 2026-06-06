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

  // Notifies the Storico page to pull history (it owns the spinner + dump
  // handling) whenever it becomes the active tab.
  final ValueNotifier<int> _storicoEnterTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() => _storeLoaded = true);
    });
    // The Live page arms its own streaming (sends L and retries until data
    // actually flows), so there is no fragile fixed-delay kickoff here — that
    // one-shot L was lost on first connect while discovery/notify were settling.
  }

  void _onTabSelected(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    if (i == 0) {
      // Returning to Live: the Live page resets its waveform and re-arms
      // streaming (resends L) off this tick.
      _liveResetTick.value++;
    } else {
      // Storico: tell the page to pull. It sends H (which stops live), shows a
      // spinner, and merges the dump silently — no snackbar on a passive switch.
      _storicoEnterTick.value++;
    }
  }

  @override
  void dispose() {
    _liveResetTick.dispose();
    _storicoEnterTick.dispose();
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
                  enterTick: _storicoEnterTick,
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
