import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';

enum AppSection {
  dashboard,
  members,
  attendance,
  events,
  routines,
  documents,
  plans,
  finance,
  library,
  settings,
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.repository,
    required this.onNavigate,
  });

  final LionRepository repository;
  final ValueChanged<AppSection> onNavigate;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late _DashboardSnapshot _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = _load();
  }

  _DashboardSnapshot _load() {
    final repository = widget.repository;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final semester = repository.getCurrentSemester();
    final members = semester == null
        ? const <Member>[]
        : repository.getMembers(semester.id, activeOnly: true);
    final sessions = semester == null
        ? const <AttendanceSession>[]
        : repository.getAttendanceSessions(semester.id);
    final events = repository.getEvents();
    final plans = semester == null
        ? const <TrainingPlanModel>[]
        : repository.getTrainingPlans(semester.id);
    final finances = repository.getFinanceEntries();

    final upcomingTraining = <AttendanceSession>[];
    final recentTraining = <AttendanceSession>[];
    for (final session in sessions) {
      final start = _sessionStart(session);
      if (start == null) continue;
      if (start.isBefore(now)) {
        recentTraining.add(session);
      } else {
        upcomingTraining.add(session);
      }
    }
    upcomingTraining.sort(
      (a, b) => _sessionStart(a)!.compareTo(_sessionStart(b)!),
    );
    recentTraining.sort(
      (a, b) => _sessionStart(b)!.compareTo(_sessionStart(a)!),
    );

    final upcomingEvents =
        events.where((event) {
            final date = _date(event.eventDate);
            return date != null && !date.isBefore(today);
          }).toList()
          ..sort((a, b) => _date(a.eventDate)!.compareTo(_date(b.eventDate)!));

    var income = 0;
    var expense = 0;
    for (final entry in finances) {
      final date = _date(entry.transactionDate);
      if (date == null || date.year != now.year || date.month != now.month) {
        continue;
      }
      if (entry.entryType == FinanceEntryType.income) {
        income += entry.amountCents;
      } else {
        expense += entry.amountCents;
      }
    }

    return _DashboardSnapshot(
      semesterLabel: semester?.label,
      memberCount: members.length,
      trainingCount: sessions.length,
      eventCount: events.length,
      routineCount: repository.getRoutines().length,
      planCount: plans.length,
      upcomingTraining: upcomingTraining.take(3).toList(growable: false),
      recentTraining: recentTraining.take(3).toList(growable: false),
      upcomingEvents: upcomingEvents.take(3).toList(growable: false),
      recentFinances: finances.take(4).toList(growable: false),
      monthIncome: income,
      monthExpense: expense,
    );
  }

  void _refresh() => setState(() => _snapshot = _load());

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < 560 ? 18.0 : 32.0;
        final contentWidth = math.min(
          1240.0,
          constraints.maxWidth - padding * 2,
        );
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(padding, 22, padding, 36),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _heading(context),
                    const SizedBox(height: 20),
                    _welcomeCard(context),
                    if (_snapshot.semesterLabel == null) ...[
                      const SizedBox(height: 14),
                      _semesterNotice(context),
                    ],
                    const SizedBox(height: 18),
                    _stats(contentWidth, colors),
                    const SizedBox(height: 20),
                    _panels(contentWidth),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _heading(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final now = DateTime.now();
    final dateLabel = '${now.year}年${now.month}月${now.day}日';

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '队伍总览',
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '训练、活动、资料与经费安排，一页掌握。',
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _InfoChip(icon: Icons.today_outlined, label: dateLabel),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _refresh,
              tooltip: '刷新总览',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ],
    );
  }

  Widget _welcomeCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final term = _snapshot.semesterLabel ?? '本地资料库';
    final showEmblem = MediaQuery.sizeOf(context).width >= 600;
    final planCount = _snapshot.planCount;

    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors.primary,
              Color.lerp(colors.primary, colors.tertiary, 0.42)!,
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -30,
              top: -64,
              child: Container(
                height: 210,
                width: 210,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colors.onPrimary.withValues(alpha: 0.13),
                    width: 27,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(26),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '狮队工作区 · $term',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelLarge?.copyWith(
                            color: colors.onPrimary.withValues(alpha: 0.78),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '把每一场训练，准备得更充分',
                          style: textTheme.headlineSmall?.copyWith(
                            color: colors.onPrimary,
                            fontWeight: FontWeight.w800,
                            height: 1.18,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          '已有 $planCount 份训练计划，随时查看队伍安排。',
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.onPrimary.withValues(alpha: 0.86),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  widget.onNavigate(AppSection.attendance),
                              icon: const Icon(Icons.fact_check_outlined),
                              label: const Text('训练考勤'),
                            ),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: colors.onPrimary,
                              ),
                              onPressed: () =>
                                  widget.onNavigate(AppSection.events),
                              icon: const Icon(Icons.event_outlined),
                              label: const Text('活动安排'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (showEmblem) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.sports_martial_arts_rounded,
                      size: 86,
                      color: colors.onPrimary.withValues(alpha: 0.82),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _semesterNotice(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: colors.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '还没有当前学期。建立学期后即可统计成员名册与训练安排。',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onTertiaryContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => widget.onNavigate(AppSection.settings),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Widget _stats(double width, ColorScheme colors) {
    final stats = [
      _Stat(
        '在册成员',
        _snapshot.memberCount,
        '当前学期',
        Icons.groups_rounded,
        colors.primary,
        colors.primaryContainer,
      ),
      _Stat(
        '本学期训练',
        _snapshot.trainingCount,
        '场次记录',
        Icons.sports_martial_arts_outlined,
        colors.tertiary,
        colors.tertiaryContainer,
      ),
      _Stat(
        '活动记录',
        _snapshot.eventCount,
        '全部活动',
        Icons.event_available_outlined,
        colors.secondary,
        colors.secondaryContainer,
      ),
      _Stat(
        '表演套路',
        _snapshot.routineCount,
        '队伍档案',
        Icons.theater_comedy_outlined,
        colors.error,
        colors.errorContainer,
      ),
    ];
    final columns = (width / 194).floor().clamp(1, 4).toInt();
    const gap = 12.0;
    final cellWidth = (width - (columns - 1) * gap) / columns;

    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: stats
          .map(
            (stat) => SizedBox(
              width: cellWidth,
              child: _StatCard(stat: stat),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _panels(double width) {
    final training = _trainingPanel();
    final eventAndFinance = Column(
      children: [_eventsPanel(), const SizedBox(height: 16), _financePanel()],
    );

    if (width >= 920) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 11, child: training),
          const SizedBox(width: 16),
          Expanded(flex: 9, child: eventAndFinance),
        ],
      );
    }
    return Column(
      children: [training, const SizedBox(height: 16), eventAndFinance],
    );
  }

  Widget _trainingPanel() {
    final upcomingCount = _snapshot.upcomingTraining.length;
    final trainingCount = _snapshot.trainingCount;
    final upcomingTitle = upcomingCount == 0
        ? '即将开始'
        : '即将开始 · $upcomingCount 场';

    return _Panel(
      title: '训练安排',
      subtitle: '本学期共 $trainingCount 场训练',
      icon: Icons.sports_martial_arts_outlined,
      onOpen: () => widget.onNavigate(AppSection.attendance),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Subheading(upcomingTitle),
          const SizedBox(height: 10),
          if (_snapshot.upcomingTraining.isEmpty)
            const _EmptyLine(
              icon: Icons.event_available_outlined,
              text: '目前没有即将开始的训练',
            )
          else
            ..._snapshot.upcomingTraining.map(
              (session) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _TrainingRow(session: session, upcoming: true),
              ),
            ),
          const SizedBox(height: 12),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 12),
          const _Subheading('最近训练'),
          const SizedBox(height: 10),
          if (_snapshot.recentTraining.isEmpty)
            const _EmptyLine(icon: Icons.history_rounded, text: '完成的训练会显示在这里')
          else
            ..._snapshot.recentTraining.map(
              (session) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _TrainingRow(session: session, upcoming: false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _eventsPanel() {
    return _Panel(
      title: '近期活动',
      subtitle: '接下来值得关注的日程',
      icon: Icons.event_outlined,
      onOpen: () => widget.onNavigate(AppSection.events),
      child: _snapshot.upcomingEvents.isEmpty
          ? const _EmptyLine(
              icon: Icons.event_busy_outlined,
              text: '暂时没有已安排的活动',
            )
          : Column(
              children: _snapshot.upcomingEvents
                  .map(
                    (event) => Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: _EventRow(event: event),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }

  Widget _financePanel() {
    final colors = Theme.of(context).colorScheme;
    final recent = _snapshot.recentFinances.take(3).toList(growable: false);
    final recentCount = recent.length;
    final recentLabel = recentCount == 0 ? '最近账目' : '最近账目 · $recentCount 条';

    return _Panel(
      title: '经费概况',
      subtitle: '本月收支与最近账目',
      icon: Icons.account_balance_wallet_outlined,
      onOpen: () => widget.onNavigate(AppSection.finance),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _MoneyTile(
                  label: '收入',
                  amount: _money(_snapshot.monthIncome),
                  icon: Icons.south_west_rounded,
                  tint: colors.primary,
                  fill: colors.primaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MoneyTile(
                  label: '支出',
                  amount: _money(_snapshot.monthExpense),
                  icon: Icons.north_east_rounded,
                  tint: colors.error,
                  fill: colors.errorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _Subheading(recentLabel),
          const SizedBox(height: 10),
          if (recent.isEmpty)
            const _EmptyLine(icon: Icons.receipt_long_outlined, text: '暂无经费记录')
          else
            ...recent.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _FinanceRow(entry: entry),
              ),
            ),
        ],
      ),
    );
  }
}

class _DashboardSnapshot {
  const _DashboardSnapshot({
    required this.semesterLabel,
    required this.memberCount,
    required this.trainingCount,
    required this.eventCount,
    required this.routineCount,
    required this.planCount,
    required this.upcomingTraining,
    required this.recentTraining,
    required this.upcomingEvents,
    required this.recentFinances,
    required this.monthIncome,
    required this.monthExpense,
  });

  final String? semesterLabel;
  final int memberCount;
  final int trainingCount;
  final int eventCount;
  final int routineCount;
  final int planCount;
  final List<AttendanceSession> upcomingTraining;
  final List<AttendanceSession> recentTraining;
  final List<EventModel> upcomingEvents;
  final List<FinanceEntryModel> recentFinances;
  final int monthIncome;
  final int monthExpense;
}

class _Stat {
  const _Stat(
    this.label,
    this.value,
    this.caption,
    this.icon,
    this.tint,
    this.fill,
  );

  final String label;
  final int value;
  final String caption;
  final IconData icon;
  final Color tint;
  final Color fill;
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 38,
                  width: 38,
                  decoration: BoxDecoration(
                    color: stat.fill,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(stat.icon, size: 20, color: stat.tint),
                ),
                const Spacer(),
                Text(
                  stat.caption,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              stat.value.toString(),
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              stat.label,
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onOpen,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 42,
                  width: 42,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: colors.primary, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onOpen,
                  tooltip: '打开$title',
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class _TrainingRow extends StatelessWidget {
  const _TrainingRow({required this.session, required this.upcoming});

  final AttendanceSession session;
  final bool upcoming;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = _date(session.sessionDate);
    final day = date?.day.toString().padLeft(2, '0') ?? '--';
    final month = date == null ? '--' : '${date.month}月';
    final time = [
      if (session.startTime.trim().isNotEmpty) session.startTime,
      if (session.endTime.trim().isNotEmpty) session.endTime,
    ].join('–');
    final dateLabel = _weekdayDate(session.sessionDate);
    final details = time.isEmpty ? dateLabel : '$dateLabel · $time';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 52,
            decoration: BoxDecoration(
              color: upcoming
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  day,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: upcoming
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  month,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: upcoming
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.title.trim().isEmpty ? '狮队训练' : session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            upcoming
                ? Icons.arrow_forward_ios_rounded
                : Icons.check_circle_outline,
            size: upcoming ? 14 : 18,
            color: upcoming ? colors.primary : colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final EventModel event;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = _date(event.eventDate);
    final dateLabel = date == null
        ? '待定'
        : '${date.month}月${date.day.toString().padLeft(2, '0')}日';
    final location = event.location.trim();
    final details = location.isEmpty ? dateLabel : '$dateLabel · $location';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          Container(
            height: 38,
            width: 38,
            decoration: BoxDecoration(
              color: colors.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.flag_outlined,
              size: 19,
              color: colors.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title.trim().isEmpty ? '未命名活动' : event.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyTile extends StatelessWidget {
  const _MoneyTile({
    required this.label,
    required this.amount,
    required this.icon,
    required this.tint,
    required this.fill,
  });

  final String label;
  final String amount;
  final IconData icon;
  final Color tint;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 25,
                height: 25,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 15, color: tint),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            amount,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800, color: tint),
          ),
        ],
      ),
    );
  }
}

class _FinanceRow extends StatelessWidget {
  const _FinanceRow({required this.entry});

  final FinanceEntryModel entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isIncome = entry.entryType == FinanceEntryType.income;
    final sign = isIncome ? '+' : '−';
    final amount = _money(entry.amountCents);
    final dateLabel = _shortDate(entry.transactionDate);

    return Row(
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: isIncome
              ? colors.primaryContainer
              : colors.errorContainer,
          child: Icon(
            isIncome ? Icons.add_rounded : Icons.remove_rounded,
            size: 18,
            color: isIncome ? colors.primary : colors.error,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.title.trim().isEmpty ? '经费记录' : entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                dateLabel,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$sign$amount',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: isIncome ? colors.primary : colors.error,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _Subheading extends StatelessWidget {
  const _Subheading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 16, color: colors.primary),
      label: Text(label),
      backgroundColor: colors.surfaceContainerLow,
      side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
      visualDensity: VisualDensity.compact,
    );
  }
}

DateTime? _date(String value) {
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

DateTime? _sessionStart(AttendanceSession session) {
  final date = _date(session.sessionDate);
  if (date == null) return null;
  final parts = session.startTime.split(':');
  final hour = int.tryParse(parts.isEmpty ? '' : parts[0]) ?? 18;
  final minute = int.tryParse(parts.length < 2 ? '' : parts[1]) ?? 0;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return DateTime(date.year, date.month, date.day, hour, minute);
}

String _money(int cents) {
  final amount = (cents.abs() / 100).toStringAsFixed(2);
  final sign = cents < 0 ? '−' : '';
  return '$sign¥$amount';
}

String _shortDate(String value) {
  final date = _date(value);
  if (date == null) return value.isEmpty ? '日期待定' : value;
  final month = date.month;
  final day = date.day;
  return '$month月$day日';
}

String _weekdayDate(String value) {
  final date = _date(value);
  if (date == null) return '日期待定';
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  final month = date.month;
  final day = date.day;
  final weekday = weekdays[date.weekday - 1];
  return '$month月$day日 周$weekday';
}
