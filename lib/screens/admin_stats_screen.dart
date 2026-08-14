// Server statistics: how large and how loaded this server currently is
// (accounts, devices, stored attachments, disk usage, queued messages,
// federation status), plus a growth history so an admin can tell whether
// storage or registrations are trending toward a problem rather than just
// reading one snapshot in isolation. Admin only, opened from AdminScreen --
// see AppSession.serverStats/serverStatsHistory.
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../net/dto.dart';
import '../state/app_session.dart';
import '../util/admin_format.dart';
import '../util/errors.dart';

class AdminStatsScreen extends StatefulWidget {
  const AdminStatsScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<AdminStatsScreen> createState() => _AdminStatsScreenState();
}

class _AdminStatsScreenState extends State<AdminStatsScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.session.refreshServerStats();
      await widget.session.refreshServerStatsHistory(days: 90);
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server Statistics')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            )
          : RefreshIndicator(onRefresh: _load, child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final stats = widget.session.serverStats;
    if (stats == null) {
      // Refreshed without throwing but still null only happens if this
      // device's role changed to non-admin between the tap that opened this
      // screen and the request landing -- same "nothing to show" a 403
      // produces elsewhere, not worth a dedicated error message for.
      return const Center(child: Text('No statistics available.'));
    }
    final history = widget.session.serverStatsHistory ?? const [];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'As of ${_formatDateTime(stats.capturedAt.toLocal())}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        _buildTileGrid(context, stats),
        const SizedBox(height: 24),
        _GrowthChart(
          title: 'Registered accounts',
          history: history,
          valueOf: (p) => p.accountCount.toDouble(),
          formatValue: (v) => v.round().toString(),
        ),
        const SizedBox(height: 24),
        _GrowthChart(
          title: 'Attachment storage',
          history: history,
          valueOf: (p) => p.blobBytes.toDouble(),
          formatValue: (v) => formatByteSize(v.round()),
        ),
      ],
    );
  }

  Widget _buildTileGrid(BuildContext context, ServerStats stats) {
    final tiles = <(String, String)>[
      (
        'Accounts',
        '${stats.activeAccountCount} active of ${stats.accountCount}',
      ),
      ('Devices', '${stats.deviceCount}'),
      ('Assets', '${stats.blobCount} (${formatByteSize(stats.blobBytes)})'),
      ('Database size', formatByteSize(stats.dbBytes)),
      ('Free disk space', _formatDiskFree(stats)),
      ('Messages queued', '${stats.pendingMessageCount}'),
      (
        'Federation',
        stats.federationEnabled
            ? '${stats.federationBlocklistCount} blocked'
            : 'disabled',
      ),
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final (label, value) in tiles)
          SizedBox(width: 160, child: _StatTile(label: label, value: value)),
      ],
    );
  }

  /// Just the free space, e.g. "82 GB" -- deliberately not "X used of Y
  /// total": the disk this server's data directory sits on is host-wide,
  /// almost always shared with other things, so a "used" figure reads as
  /// this server's own usage when it mostly isn't. Free space is the one
  /// number that answers "is this server about to run out of room"
  /// regardless of what else lives on that disk. "unknown" when the host
  /// platform has no way to report it at all (internal/diskstat, e.g. this
  /// server currently runs on something other than Linux/Darwin).
  String _formatDiskFree(ServerStats stats) {
    if (stats.diskTotalBytes <= 0) return 'unknown';
    return formatByteSize(stats.diskFreeBytes);
  }

}

/// One growth line chart over a paged time window: ‹ › below the chart
/// move the window a whole span at a time (the span itself is named between
/// them), the x-axis carries short dates at intervals, and a tap or drag on
/// the line marks a point and names its exact time and value in a bubble.
///
/// The bubble and its marker are driven from this widget's own state
/// (`showingTooltipIndicators`/`showingIndicators` with
/// `handleBuiltInTouches: false`) rather than fl_chart's built-in touch
/// handling, which clears both the instant a finger lifts -- on a phone
/// that leaves no way to actually read the value. Gestures still reach us
/// either way (fl_chart feeds its pan/tap recognizers whenever a
/// touchCallback is set), so dragging along the line keeps working.
class _GrowthChart extends StatefulWidget {
  const _GrowthChart({
    required this.title,
    required this.history,
    required this.valueOf,
    required this.formatValue,
  });

  final String title;
  final List<ServerStatsPoint> history;
  final double Function(ServerStatsPoint) valueOf;
  final String Function(double) formatValue;

  @override
  State<_GrowthChart> createState() => _GrowthChartState();
}

class _GrowthChartState extends State<_GrowthChart> {
  /// How much time one page of the chart covers, and how far apart the
  /// x-axis dates are placed. Four labels across a window is about as many
  /// as fit on a phone before short dates start touching each other.
  static const _windowDays = 28;
  static const _labelIntervalDays = 7;

  /// How many whole windows back from the newest snapshot we are showing.
  /// 0 is the most recent window.
  int _windowsBack = 0;

  /// The point the bubble is pinned to, as an index into the *visible*
  /// points of the current window. Null means nothing is marked yet.
  int? _selectedIndex;

  @override
  void didUpdateWidget(_GrowthChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh replaces the series, so an index into the old one means
    // nothing -- drop the marker rather than pin it to a different point.
    if (widget.history != oldWidget.history) {
      _selectedIndex = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = widget.history;
    final label = Text(widget.title, style: theme.textTheme.titleSmall);

    // A single point (or none) has no trend to draw -- a fresh server
    // hasn't had time to accumulate a second snapshot yet.
    if (history.length < 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(height: 8),
          Text(
            'Not enough history yet -- check back once more snapshots '
            'have been recorded.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }

    // Windows are cut by date rather than by counting points, so the range
    // named between the arrows is the range actually drawn even where
    // snapshots are missing (a server that was down records nothing).
    final newest = history.last.capturedAt.toLocal();
    final windowEnd = newest.subtract(
      Duration(days: _windowDays * _windowsBack),
    );
    final windowStart = windowEnd.subtract(const Duration(days: _windowDays));

    final visible = [
      for (final p in history)
        if (!p.capturedAt.toLocal().isBefore(windowStart) &&
            !p.capturedAt.toLocal().isAfter(windowEnd))
          p,
    ];

    final hasOlder = history.first.capturedAt.toLocal().isBefore(windowStart);
    final selected =
        _selectedIndex != null &&
            _selectedIndex! >= 0 &&
            _selectedIndex! < visible.length
        ? _selectedIndex!
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label,
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: visible.length < 2
              // Paging can legitimately land on a window with nothing in
              // it, which has to say so rather than draw an empty frame the
              // reader would take for "zero".
              ? Center(
                  child: Text(
                    'No snapshots in this range.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : _buildChart(context, visible, windowStart, windowEnd, selected),
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Earlier',
              onPressed: hasOlder
                  ? () => setState(() {
                      _windowsBack++;
                      _selectedIndex = null;
                    })
                  : null,
            ),
            Expanded(
              child: Text(
                _formatRange(windowStart, windowEnd),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Later',
              onPressed: _windowsBack > 0
                  ? () => setState(() {
                      _windowsBack--;
                      _selectedIndex = null;
                    })
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildChart(
    BuildContext context,
    List<ServerStatsPoint> visible,
    DateTime windowStart,
    DateTime windowEnd,
    int? selected,
  ) {
    final theme = Theme.of(context);

    // x is the real instant, not a running index, so gaps in the series
    // show as gaps and the axis dates land where they belong.
    final bar = LineChartBarData(
      spots: [
        for (final p in visible)
          FlSpot(
            p.capturedAt.millisecondsSinceEpoch.toDouble(),
            widget.valueOf(p),
          ),
      ],
      isCurved: false,
      barWidth: 2,
      dotData: const FlDotData(show: false),
      color: theme.colorScheme.primary,
      showingIndicators: selected == null ? const [] : [selected],
    );

    return LineChart(
      LineChartData(
        minX: windowStart.millisecondsSinceEpoch.toDouble(),
        maxX: windowEnd.millisecondsSinceEpoch.toDouble(),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          topTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: const Duration(days: _labelIntervalDays)
                  .inMilliseconds
                  .toDouble(),
              // Only the interval ticks: fl_chart would otherwise also
              // force a label at each end, which on a narrow screen lands
              // right next to its neighbour.
              minIncluded: false,
              maxIncluded: false,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                child: Text(
                  _formatShortDate(
                    DateTime.fromMillisecondsSinceEpoch(value.toInt()),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          // We drive the bubble and marker ourselves so both survive the
          // finger lifting -- see the class doc comment.
          handleBuiltInTouches: false,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) => [
              for (final s in touchedSpots)
                LineTooltipItem(
                  '${_formatDateTime(visible[s.spotIndex].capturedAt.toLocal())}\n'
                  '${widget.formatValue(s.y)}',
                  TextStyle(color: theme.colorScheme.onInverseSurface),
                ),
            ],
          ),
          touchCallback: (event, response) {
            final touched = response?.lineBarSpots;
            if (touched == null || touched.isEmpty) return;
            final index = touched.first.spotIndex;
            if (index == _selectedIndex) return;
            setState(() => _selectedIndex = index);
          },
        ),
        // Pinning the bubble to the marked spot is what keeps it on screen
        // after release; fl_chart draws these regardless of touch state.
        showingTooltipIndicators: selected == null
            ? const []
            : [
                ShowingTooltipIndicators([
                  LineBarSpot(bar, 0, bar.spots[selected]),
                ]),
              ],
        lineBarsData: [bar],
      ),
    );
  }
}

const _shortMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "14 Aug" -- short enough that four of them fit across a phone-width
/// x-axis without running together.
String _formatShortDate(DateTime t) => '${t.day} ${_shortMonths[t.month - 1]}';

/// The window named between the paging arrows, e.g. "17 Jul – 14 Aug 2026".
/// The year is stated once, or on both ends when the window straddles a
/// year boundary.
String _formatRange(DateTime from, DateTime to) {
  if (from.year != to.year) {
    return '${_formatShortDate(from)} ${from.year} – '
        '${_formatShortDate(to)} ${to.year}';
  }
  return '${_formatShortDate(from)} – ${_formatShortDate(to)} ${to.year}';
}

String _formatDate(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

String _formatDateTime(DateTime t) =>
    '${_formatDate(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
