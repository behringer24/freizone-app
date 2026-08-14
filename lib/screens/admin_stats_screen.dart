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
          // The live reading joins the recorded ones, so the measured line ends
          // at "now" rather than at the last snapshot -- which is also where the
          // forecast starts, and the two have to meet exactly.
          liveAt: stats.capturedAt,
          liveValue: stats.blobBytes.toDouble(),
          forecast: stats.forecast,
        ),
        if (stats.forecast != null) ...[
          const SizedBox(height: 8),
          _ForecastNote(forecast: stats.forecast!),
        ],
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
    this.liveAt,
    this.liveValue,
    this.forecast,
  });

  final String title;
  final List<ServerStatsPoint> history;
  final double Function(ServerStatsPoint) valueOf;
  final String Function(double) formatValue;

  /// The live reading, appended to the recorded ones so the measured line ends
  /// at "now" instead of at the last snapshot — which is where [forecast]
  /// begins, and the two must meet exactly or the join reads as a step.
  final DateTime? liveAt;
  final double? liveValue;

  /// When given, two more lines continue past today: the exact decay of what is
  /// stored now, and the same plus uploads continuing at the measured rate.
  /// Null for a figure that has no forecast (registrations do not expire) or a
  /// server that does not report one.
  final StorageForecast? forecast;

  @override
  State<_GrowthChart> createState() => _GrowthChartState();
}

/// One drawn line: its points, how it is painted, and what to call it in the
/// bubble. Three of them at most -- measured, drain, drain-plus-inflow.
class _ChartSeries {
  _ChartSeries({
    required this.label,
    required this.points,
    required this.color,
    this.dashed = false,
  });

  final String label;
  final List<({DateTime at, double value})> points;
  final Color color;
  final bool dashed;
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

  /// Which point the bubble is pinned to: the series it belongs to and its
  /// index within that series' visible points. Null means nothing is marked.
  ({int series, int index})? _selected;

  @override
  void didUpdateWidget(_GrowthChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh replaces the series, so an index into the old one means
    // nothing -- drop the marker rather than pin it to a different point.
    if (widget.history != oldWidget.history ||
        widget.forecast != oldWidget.forecast) {
      _selected = null;
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

    // The forecast only belongs on the newest page -- older pages are history,
    // and a projection drawn beside them would claim to be about their time.
    final forecast = _windowsBack == 0 ? widget.forecast : null;
    final showsForecast =
        forecast != null && forecast.drain.length >= 2 && widget.liveAt != null;

    final measured = <({DateTime at, double value})>[
      for (final p in history)
        if (!p.capturedAt.toLocal().isBefore(windowStart) &&
            !p.capturedAt.toLocal().isAfter(windowEnd))
          (at: p.capturedAt.toLocal(), value: widget.valueOf(p)),
      // Appended last so the line runs right up to now, where the forecast
      // takes over. Only on the newest page, and only if it is inside it.
      if (_windowsBack == 0 &&
          widget.liveAt != null &&
          widget.liveValue != null &&
          !widget.liveAt!.toLocal().isBefore(windowStart))
        (at: widget.liveAt!.toLocal(), value: widget.liveValue!),
    ];

    final series = <_ChartSeries>[
      _ChartSeries(
        label: 'Stored',
        points: measured,
        color: theme.colorScheme.primary,
      ),
      if (showsForecast) ...[
        _ChartSeries(
          // Neutral and dashed: this is a calculation, and it must not read as
          // another measurement. colorScheme.outline rather than a hard-coded
          // grey, which is the whole difference between working and unreadable
          // in dark mode.
          label: 'If unread',
          points: [
            for (final p in forecast.drain)
              (at: p.at.toLocal(), value: p.bytes.toDouble()),
          ],
          color: theme.colorScheme.outline,
          dashed: true,
        ),
        _ChartSeries(
          // Same hue as the measurement, dimmed: it continues that quantity
          // rather than describing a different one.
          label: 'If uploads continue',
          points: [
            for (final p in forecast.withInflow)
              (at: p.at.toLocal(), value: p.bytes.toDouble()),
          ],
          color: theme.colorScheme.primary.withValues(alpha: 0.45),
        ),
      ],
    ];

    // The drawn range runs past today when a forecast is shown, so the arrows
    // page a window that is history on the left and calculation on the right.
    final rightEdge = showsForecast ? forecast.drain.last.at.toLocal() : windowEnd;
    final hasOlder = history.first.capturedAt.toLocal().isBefore(windowStart);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label,
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: measured.length < 2
              // Paging can legitimately land on a window with nothing in
              // it, which has to say so rather than draw an empty frame the
              // reader would take for "zero".
              ? Center(
                  child: Text(
                    'No snapshots in this range.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : _buildChart(
                  context,
                  series,
                  windowStart,
                  rightEdge,
                  showsForecast ? widget.liveAt!.toLocal() : null,
                ),
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Earlier',
              onPressed: hasOlder
                  ? () => setState(() {
                      _windowsBack++;
                      _selected = null;
                    })
                  : null,
            ),
            Expanded(
              child: Text(
                _formatRange(windowStart, rightEdge),
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
                      _selected = null;
                    })
                  : null,
            ),
          ],
        ),
        if (showsForecast) _ChartLegend(series: series),
      ],
    );
  }

  /// Whether line [candidate] should be pinned when line [touched] was hit. The
  /// two forecast lines (1 and 2) are index-aligned in time, so they answer
  /// together; the measured line stands alone.
  bool _pinsWith(int candidate, int touched) {
    if (candidate == touched) return true;
    return touched > 0 && candidate > 0;
  }

  Widget _buildChart(
    BuildContext context,
    List<_ChartSeries> series,
    DateTime windowStart,
    DateTime windowEnd,
    DateTime? todayAt,
  ) {
    final theme = Theme.of(context);

    // x is the real instant, not a running index, so gaps in a series show as
    // gaps, the three lines line up in time, and the axis dates land where they
    // belong.
    final bars = <LineChartBarData>[
      for (var i = 0; i < series.length; i++)
        LineChartBarData(
          spots: [
            for (final p in series[i].points)
              FlSpot(p.at.millisecondsSinceEpoch.toDouble(), p.value),
          ],
          isCurved: false,
          barWidth: 2,
          dashArray: series[i].dashed ? const [6, 4] : null,
          dotData: const FlDotData(show: false),
          color: series[i].color,
          showingIndicators: _selected?.series == i ? [_selected!.index] : const [],
        ),
    ];

    return LineChart(
      LineChartData(
        minX: windowStart.millisecondsSinceEpoch.toDouble(),
        maxX: windowEnd.millisecondsSinceEpoch.toDouble(),
        // Where measurement ends and arithmetic begins. Without it the three
        // lines are one continuous picture and nothing says which part is a
        // record of what happened.
        extraLinesData: ExtraLinesData(
          extraLinesOnTop: false,
          verticalLines: [
            if (todayAt != null)
              VerticalLine(
                x: todayAt.millisecondsSinceEpoch.toDouble(),
                color: theme.colorScheme.outlineVariant,
                strokeWidth: 1,
                dashArray: const [3, 3],
              ),
          ],
        ),
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
            getTooltipColor: (_) => theme.colorScheme.inverseSurface,
            getTooltipItems: (touchedSpots) => [
              for (var i = 0; i < touchedSpots.length; i++)
                LineTooltipItem(
                  // The time once, on the first row, then one named value per
                  // line that has a point here. Named rather than colour-coded:
                  // the tooltip has its own background, so a line's colour is
                  // not guaranteed legible on it in both themes, and "If
                  // unread" says more than a grey swatch anyway.
                  '${i == 0 ? '${_formatDateTime(DateTime.fromMillisecondsSinceEpoch(touchedSpots[i].x.toInt()))}\n' : ''}'
                  '${series[touchedSpots[i].barIndex].label}: '
                  '${widget.formatValue(touchedSpots[i].y)}',
                  TextStyle(color: theme.colorScheme.onInverseSurface),
                  textAlign: TextAlign.left,
                ),
            ],
          ),
          touchCallback: (event, response) {
            final touched = response?.lineBarSpots;
            if (touched == null || touched.isEmpty) return;
            final hit = (
              series: touched.first.barIndex,
              index: touched.first.spotIndex,
            );
            if (hit == _selected) return;
            setState(() => _selected = hit);
          },
        ),
        // Pinning the bubble is what keeps it on screen after release; fl_chart
        // draws these regardless of touch state.
        //
        // The two forecast lines share their instants point for point, so
        // touching either pins both and the bubble answers the real question --
        // "how much if nobody reads it, how much if uploads keep coming" -- side
        // by side. In the measured part there is only ever one line to pin.
        showingTooltipIndicators: _selected == null
            ? const []
            : [
                ShowingTooltipIndicators([
                  for (var i = 0; i < bars.length; i++)
                    if (_pinsWith(i, _selected!.series) &&
                        _selected!.index < bars[i].spots.length)
                      LineBarSpot(bars[i], i, bars[i].spots[_selected!.index]),
                ]),
              ],
        lineBarsData: bars,
      ),
    );
  }
}

/// Names the three lines, because a dashed neutral line and a dimmed teal one
/// are not self-explanatory and the bubble only speaks when touched.
class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.series});

  final List<_ChartSeries> series;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          for (final s in series)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A short stroke rather than a dot, so a dashed line reads as
                // dashed in the key too.
                CustomPaint(
                  size: const Size(16, 2),
                  painter: _StrokeSwatch(color: s.color, dashed: s.dashed),
                ),
                const SizedBox(width: 6),
                Text(
                  s.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _StrokeSwatch extends CustomPainter {
  _StrokeSwatch({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
      return;
    }
    const dash = 4.0;
    const gap = 3.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset((x + dash).clamp(0, size.width), size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StrokeSwatch old) =>
      old.color != color || old.dashed != dashed;
}

/// The forecast in words, under the chart: the rate it was measured at and the
/// level storage settles on. The chart shows the shape; this says what it means,
/// and states the one assumption out loud.
class _ForecastNote extends StatelessWidget {
  const _ForecastNote({required this.forecast});

  final StorageForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (forecast.inflowBytesPerDay <= 0) {
      return Text(
        'Nothing has been uploaded in the last '
        '${forecast.inflowWindowDays} days, so there is no growth to project. '
        'Attachments are kept ${forecast.retentionDays} days, then released.',
        style: style,
      );
    }
    return Text(
      '${formatByteSize(forecast.inflowBytesPerDay)} per day uploaded over the '
      'last ${forecast.inflowWindowDays} days. Attachments are kept '
      '${forecast.retentionDays} days, so at that rate storage settles at about '
      '${formatByteSize(forecast.equilibriumBytes)} rather than growing without '
      'limit. The dashed line is the upper bound: what stays if nobody reads '
      'anything, since a picture is released as soon as its recipient has it.',
      style: style,
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
