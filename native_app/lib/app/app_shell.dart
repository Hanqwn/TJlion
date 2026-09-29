import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../features/attendance_page.dart';
import '../features/archives_page.dart';
import '../features/dashboard_page.dart';
import '../features/daily_training_page.dart';
import '../features/events_page.dart';
import '../features/finance_page.dart';
import '../features/library_page.dart';
import '../features/inventory_page.dart';
import '../features/members_page.dart';
import '../features/plans_reports_page.dart';
import '../features/routines_page.dart';
import '../features/settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const List<_AppDestination> _destinations = [
    _AppDestination(
      section: _ShellSection.dashboard,
      title: '总览',
      icon: Icons.space_dashboard_outlined,
      selectedIcon: Icons.space_dashboard_rounded,
    ),
    _AppDestination(
      section: _ShellSection.members,
      title: '成员资料',
      icon: Icons.groups_outlined,
      selectedIcon: Icons.groups_rounded,
    ),
    _AppDestination(
      section: _ShellSection.attendance,
      title: '训练考勤',
      icon: Icons.fact_check_outlined,
      selectedIcon: Icons.fact_check_rounded,
    ),
    _AppDestination(
      section: _ShellSection.daily,
      title: '日常',
      icon: Icons.fitness_center_outlined,
      selectedIcon: Icons.fitness_center,
    ),
    _AppDestination(
      section: _ShellSection.events,
      title: '活动相册',
      icon: Icons.event_outlined,
      selectedIcon: Icons.event_rounded,
    ),
    _AppDestination(
      section: _ShellSection.routines,
      title: '表演套路',
      icon: Icons.theater_comedy_outlined,
      selectedIcon: Icons.theater_comedy,
    ),
    _AppDestination(
      section: _ShellSection.documents,
      title: '通讯与总结',
      icon: Icons.article_outlined,
      selectedIcon: Icons.article_rounded,
    ),
    _AppDestination(
      section: _ShellSection.plans,
      title: '训练计划',
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month_rounded,
    ),
    _AppDestination(
      section: _ShellSection.finance,
      title: '经费账本',
      icon: Icons.account_balance_wallet_outlined,
      selectedIcon: Icons.account_balance_wallet_rounded,
    ),
    _AppDestination(
      section: _ShellSection.library,
      title: '历史资料库',
      icon: Icons.folder_open_outlined,
      selectedIcon: Icons.folder_rounded,
    ),
    _AppDestination(
      section: _ShellSection.archives,
      title: '档案馆',
      icon: Icons.archive_outlined,
      selectedIcon: Icons.archive_rounded,
    ),
    _AppDestination(
      section: _ShellSection.inventory,
      title: '道具',
      icon: Icons.inventory_2_outlined,
      selectedIcon: Icons.inventory_2_rounded,
    ),
    _AppDestination(
      section: _ShellSection.settings,
      title: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
    ),
  ];

  _ShellSection _selectedSection = _ShellSection.dashboard;

  String? get _semesterLabel => widget.repository.getCurrentSemester()?.label;

  _AppDestination get _selectedDestination => _destinations.firstWhere(
    (destination) => destination.section == _selectedSection,
  );

  void _navigate(_ShellSection section) {
    if (section == _selectedSection) return;
    setState(() => _selectedSection = section);
  }

  void _refreshCurrentSemester() {
    if (mounted) setState(() {});
  }

  Widget _buildPage() {
    final repository = widget.repository;
    return switch (_selectedSection) {
      _ShellSection.dashboard => DashboardPage(
        repository: repository,
        onNavigate: (section) => _navigate(_shellSectionFromDashboard(section)),
      ),
      _ShellSection.members => MembersPage(
        repository: repository,
        onCurrentSemesterChanged: _refreshCurrentSemester,
      ),
      _ShellSection.attendance => AttendancePage(repository: repository),
      _ShellSection.daily => DailyTrainingPage(repository: repository),
      _ShellSection.events => EventsPage(repository: repository),
      _ShellSection.routines => RoutinesPage(repository: repository),
      _ShellSection.documents => ReportsPage(
        key: const ValueKey(_ShellSection.documents),
        repository: repository,
      ),
      _ShellSection.plans => TrainingPlansPage(repository: repository),
      _ShellSection.finance => FinancePage(repository: repository),
      _ShellSection.library => LibraryPage(repository: repository),
      _ShellSection.archives => ArchivesPage(
        repository: repository,
        onNavigate: (section) => _navigate(_shellSectionFromDashboard(section)),
      ),
      _ShellSection.inventory => InventoryPage(repository: repository),
      _ShellSection.settings => SettingsPage(repository: repository),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= 900;
    final isExtendedRail = width >= 1320;
    final railLabelStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(fontSize: 12, fontWeight: FontWeight.w500);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        surfaceTintColor: colors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leadingWidth: 62,
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 0, 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Center(
              child: Text(
                '狮',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: colors.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
        titleSpacing: 8,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _selectedDestination.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              '狮队管理台 · ${_semesterLabel ?? '尚未设置当前学期'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (width >= 620)
            Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.storage_outlined,
                      size: 17,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '仅保存在本机',
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            )
          else
            IconButton(
              tooltip: '数据仅保存在本机',
              onPressed: null,
              icon: const Icon(Icons.storage_outlined),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: isDesktop
            ? Row(
                children: [
                  Container(
                    width: isExtendedRail ? 244 : 84,
                    color: colors.surface,
                    child: NavigationRailTheme(
                      data: NavigationRailThemeData(
                        selectedLabelTextStyle: railLabelStyle,
                        unselectedLabelTextStyle: railLabelStyle,
                      ),
                      child: NavigationRail(
                        selectedIndex: _destinations.indexOf(
                          _selectedDestination,
                        ),
                        onDestinationSelected: (index) =>
                            _navigate(_destinations[index].section),
                        extended: isExtendedRail,
                        minWidth: 76,
                        minExtendedWidth: 228,
                        labelType: isExtendedRail
                            ? NavigationRailLabelType.none
                            : NavigationRailLabelType.all,
                        groupAlignment: -1,
                        useIndicator: true,
                        scrollable: true,
                        destinations: _destinations
                            .map(
                              (destination) => NavigationRailDestination(
                                icon: Tooltip(
                                  message: destination.title,
                                  child: Icon(destination.icon),
                                ),
                                selectedIcon: Icon(destination.selectedIcon),
                                label: Text(
                                  destination.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                  Expanded(child: _buildPage()),
                ],
              )
            : _buildPage(),
      ),
      bottomNavigationBar: isDesktop
          ? null
          : NavigationBar(
              height: 66,
              selectedIndex: _destinations.indexOf(_selectedDestination),
              onDestinationSelected: (index) =>
                  _navigate(_destinations[index].section),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              destinations: _destinations
                  .map(
                    (destination) => NavigationDestination(
                      icon: Tooltip(
                        message: destination.title,
                        child: Icon(destination.icon, size: 21),
                      ),
                      selectedIcon: Icon(destination.selectedIcon, size: 21),
                      label: destination.title,
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _AppDestination {
  const _AppDestination({
    required this.section,
    required this.title,
    required this.icon,
    required this.selectedIcon,
  });

  final _ShellSection section;
  final String title;
  final IconData icon;
  final IconData selectedIcon;
}

enum _ShellSection {
  dashboard,
  members,
  attendance,
  daily,
  events,
  routines,
  documents,
  plans,
  finance,
  library,
  archives,
  inventory,
  settings,
}

_ShellSection _shellSectionFromDashboard(AppSection section) =>
    switch (section) {
      AppSection.dashboard => _ShellSection.dashboard,
      AppSection.members => _ShellSection.members,
      AppSection.attendance => _ShellSection.attendance,
      AppSection.events => _ShellSection.events,
      AppSection.routines => _ShellSection.routines,
      AppSection.documents => _ShellSection.documents,
      AppSection.plans => _ShellSection.plans,
      AppSection.finance => _ShellSection.finance,
      AppSection.library => _ShellSection.library,
      AppSection.settings => _ShellSection.settings,
    };
