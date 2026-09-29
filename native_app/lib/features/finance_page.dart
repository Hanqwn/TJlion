import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';

class FinancePage extends StatefulWidget {
  const FinancePage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends State<FinancePage> {
  final TextEditingController _searchController = TextEditingController();
  List<FinanceEntryModel> _entries = const [];
  List<Member> _members = const [];
  FinanceEntryType? _typeFilter;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    final repository = widget.repository;
    final entries = repository.getFinanceEntries();
    final semester = repository.getCurrentSemester();
    final members = semester == null
        ? <Member>[]
        : <Member>[...repository.getMembers(semester.id)];
    final memberIds = members.map((member) => member.id).toSet();
    for (final entry in entries) {
      final id = entry.memberId;
      if (id == null || memberIds.contains(id)) continue;
      final historicalMember = repository.getMember(id);
      if (historicalMember != null) {
        members.add(historicalMember);
        memberIds.add(id);
      }
    }
    setState(() {
      _entries = entries;
      _members = members;
    });
  }

  List<FinanceEntryModel> get _visibleEntries {
    final query = _searchController.text.trim().toLowerCase();
    return _entries
        .where((entry) {
          if (_typeFilter != null && entry.entryType != _typeFilter)
            return false;
          if (query.isEmpty) return true;
          final member = _memberName(entry.memberId);
          return entry.title.toLowerCase().contains(query) ||
              entry.notes.toLowerCase().contains(query) ||
              member.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  String _memberName(int? memberId) {
    if (memberId == null) return '';
    for (final member in _members) {
      if (member.id == memberId) return member.name;
    }
    return '';
  }

  Future<void> _editEntry([FinanceEntryModel? entry]) async {
    final draft = await showDialog<_FinanceDraft>(
      context: context,
      builder: (context) =>
          _FinanceEntryDialog(entry: entry, members: _members),
    );
    if (draft == null || !mounted) return;

    try {
      if (entry == null) {
        widget.repository.addFinanceEntry(
          transactionDate: draft.date,
          entryType: draft.type,
          title: draft.title,
          amountCents: draft.amountCents,
          memberId: draft.memberId,
          notes: draft.notes,
        );
        _showMessage('账目已添加');
      } else {
        widget.repository.updateFinanceEntry(
          FinanceEntryModel(
            id: entry.id,
            transactionDate: draft.date,
            entryType: draft.type,
            title: draft.title,
            amountCents: draft.amountCents,
            memberId: draft.memberId,
            notes: draft.notes,
            createdAt: entry.createdAt,
          ),
        );
        _showMessage('账目已更新');
      }
      _reload();
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _deleteEntry(FinanceEntryModel entry) async {
    final entryTitle = entry.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条账目？'),
        content: Text('“$entryTitle”将从经费记录中删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.repository.deleteFinanceEntry(entry.id);
      _reload();
      _showMessage('账目已删除');
    } catch (error) {
      _showMessage('删除失败：$error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    var monthIncome = 0;
    var monthExpense = 0;
    for (final entry in _entries) {
      final date = _parseFinanceDate(entry.transactionDate);
      if (date == null || date.year != now.year || date.month != now.month) {
        continue;
      }
      if (entry.entryType == FinanceEntryType.income) {
        monthIncome += entry.amountCents;
      } else {
        monthExpense += entry.amountCents;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 560 ? 18.0 : 30.0;
        final contentWidth = (constraints.maxWidth - horizontalPadding * 2)
            .clamp(0.0, 1180.0)
            .toDouble();
        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            22,
            horizontalPadding,
            20,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeading(context),
                  const SizedBox(height: 18),
                  _buildSummary(contentWidth, monthIncome, monthExpense),
                  const SizedBox(height: 18),
                  _buildFilters(context),
                  const SizedBox(height: 12),
                  Expanded(child: _buildEntryList()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeading(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
              '经费账本',
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '查看收入、日常支出与活动工资，随时维护每笔记录。',
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        FilledButton.icon(
          onPressed: () => _editEntry(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('新增账目'),
        ),
      ],
    );
  }

  Widget _buildSummary(double width, int income, int expense) {
    final colors = Theme.of(context).colorScheme;
    final net = income - expense;
    final stats = [
      _FinanceSummary(
        label: '本月收入',
        amount: income,
        icon: Icons.south_west_rounded,
        tint: colors.primary,
        fill: colors.primaryContainer,
      ),
      _FinanceSummary(
        label: '本月支出与工资',
        amount: expense,
        icon: Icons.north_east_rounded,
        tint: colors.error,
        fill: colors.errorContainer,
      ),
      _FinanceSummary(
        label: '本月结余',
        amount: net,
        icon: Icons.account_balance_wallet_outlined,
        tint: net >= 0 ? colors.tertiary : colors.error,
        fill: net >= 0 ? colors.tertiaryContainer : colors.errorContainer,
      ),
    ];
    final columns = (width / 250).floor().clamp(1, 3).toInt();
    const gap = 12.0;
    final cellWidth = (width - (columns - 1) * gap) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: stats
          .map(
            (stat) => SizedBox(
              width: cellWidth,
              child: _SummaryCard(summary: stat),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildFilters(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filters = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _typeChip(null, '全部'),
        _typeChip(FinanceEntryType.income, '收入'),
        _typeChip(FinanceEntryType.expense, '支出'),
        _typeChip(FinanceEntryType.wage, '活动工资'),
      ],
    );
    final search = SizedBox(
      width: 300,
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索标题、备注或成员',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除搜索',
                  onPressed: _searchController.clear,
                  icon: const Icon(Icons.close),
                ),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 720) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [filters, const SizedBox(height: 12), search],
              );
            }
            return Row(
              children: [
                Expanded(child: filters),
                const SizedBox(width: 16),
                search,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _typeChip(FinanceEntryType? type, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _typeFilter == type,
      onSelected: (_) => setState(() => _typeFilter = type),
    );
  }

  Widget _buildEntryList() {
    final visible = _visibleEntries;
    if (visible.isEmpty) {
      final hasData = _entries.isNotEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasData
                    ? Icons.search_off_rounded
                    : Icons.receipt_long_outlined,
                size: 46,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                hasData ? '没有找到匹配的账目' : '还没有经费记录',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                hasData ? '试试其他关键词或账目类型。' : '添加第一笔收入、支出或活动工资。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: visible.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = visible[index];
        return _FinanceEntryCard(
          entry: entry,
          memberName: _memberName(entry.memberId),
          onEdit: () => _editEntry(entry),
          onDelete: () => _deleteEntry(entry),
        );
      },
    );
  }
}

class _FinanceSummary {
  const _FinanceSummary({
    required this.label,
    required this.amount,
    required this.icon,
    required this.tint,
    required this.fill,
  });

  final String label;
  final int amount;
  final IconData icon;
  final Color tint;
  final Color fill;
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final _FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: summary.fill,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(summary.icon, color: summary.tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatMoney(summary.amount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: summary.tint,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceEntryCard extends StatelessWidget {
  const _FinanceEntryCard({
    required this.entry,
    required this.memberName,
    required this.onEdit,
    required this.onDelete,
  });

  final FinanceEntryModel entry;
  final String memberName;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isIncome = entry.entryType == FinanceEntryType.income;
    final isWage = entry.entryType == FinanceEntryType.wage;
    final title = entry.title.trim().isEmpty ? '经费记录' : entry.title.trim();
    final amountText = _formatMoney(entry.amountCents);
    final signedAmount = isIncome ? '+$amountText' : '−$amountText';
    final details = <String>[
      _formatDate(entry.transactionDate),
      _typeLabel(entry.entryType),
      if (memberName.isNotEmpty) memberName,
    ].join(' · ');
    final notes = entry.notes.trim();

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 21,
              backgroundColor: isIncome
                  ? colors.primaryContainer
                  : isWage
                  ? colors.tertiaryContainer
                  : colors.errorContainer,
              child: Icon(
                isIncome
                    ? Icons.add_rounded
                    : isWage
                    ? Icons.volunteer_activism_outlined
                    : Icons.remove_rounded,
                color: isIncome
                    ? colors.primary
                    : isWage
                    ? colors.tertiary
                    : colors.error,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
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
                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      notes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  signedAmount,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: isIncome
                        ? colors.primary
                        : isWage
                        ? colors.tertiary
                        : colors.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '编辑账目',
                      visualDensity: VisualDensity.compact,
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 19),
                    ),
                    IconButton(
                      tooltip: '删除账目',
                      visualDensity: VisualDensity.compact,
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: colors.error,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceEntryDialog extends StatefulWidget {
  const _FinanceEntryDialog({required this.entry, required this.members});

  final FinanceEntryModel? entry;
  final List<Member> members;

  @override
  State<_FinanceEntryDialog> createState() => _FinanceEntryDialogState();
}

class _FinanceEntryDialogState extends State<_FinanceEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _dateController;
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _notesController;
  late FinanceEntryType _type;
  int? _memberId;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    final now = DateTime.now();
    _dateController = TextEditingController(
      text: entry?.transactionDate ?? _isoDate(now),
    );
    _titleController = TextEditingController(text: entry?.title ?? '');
    _amountController = TextEditingController(
      text: entry == null ? '' : (entry.amountCents / 100).toStringAsFixed(2),
    );
    _notesController = TextEditingController(text: entry?.notes ?? '');
    _type = entry?.entryType ?? FinanceEntryType.expense;
    _memberId = entry?.memberId;
  }

  @override
  void dispose() {
    _dateController.dispose();
    _titleController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final selected = _parseFinanceDate(_dateController.text) ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择账目日期',
    );
    if (date != null) _dateController.text = _isoDate(date);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final parsedAmount = double.parse(_amountController.text.trim());
    final cents = (parsedAmount * 100).round();
    final date = _isoDate(_parseFinanceDate(_dateController.text.trim())!);
    Navigator.pop(
      context,
      _FinanceDraft(
        date: date,
        type: _type,
        title: _titleController.text.trim(),
        amountCents: cents,
        memberId: _type == FinanceEntryType.wage ? _memberId : null,
        notes: _notesController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? '新增账目' : '编辑账目'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<FinanceEntryType>(
                  initialValue: _type,
                  decoration: const InputDecoration(
                    labelText: '账目类型',
                    prefixIcon: Icon(Icons.category_outlined),
                    border: OutlineInputBorder(),
                  ),
                  items: FinanceEntryType.values
                      .map(
                        (type) => DropdownMenuItem(
                          value: type,
                          child: Text(_typeLabel(type)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) setState(() => _type = value);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _titleController,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '标题 *',
                    hintText: '例如：器材采购、演出收入',
                    prefixIcon: Icon(Icons.edit_note_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入账目标题' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _dateController,
                        decoration: InputDecoration(
                          labelText: '日期 *',
                          hintText: 'YYYY-MM-DD',
                          prefixIcon: const Icon(Icons.calendar_today_outlined),
                          suffixIcon: IconButton(
                            tooltip: '选择日期',
                            onPressed: _pickDate,
                            icon: const Icon(Icons.event_outlined),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            _parseFinanceDate(value ?? '') == null
                            ? '请输入有效日期'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '金额（元）*',
                          prefixText: '¥ ',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final amount = double.tryParse((value ?? '').trim());
                          if (amount == null ||
                              !amount.isFinite ||
                              amount <= 0) {
                            return '请输入大于 0 的金额';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                if (_type == FinanceEntryType.wage) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    initialValue: _memberId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '关联成员（可选）',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('不关联成员'),
                      ),
                      ...widget.members.map(
                        (member) => DropdownMenuItem<int?>(
                          value: member.id,
                          child: Text(
                            member.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() => _memberId = value),
                  ),
                  if (widget.members.isEmpty) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '当前学期还没有成员名册，可先保存未关联成员的工资记录。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notesController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存账目')),
      ],
    );
  }
}

class _FinanceDraft {
  const _FinanceDraft({
    required this.date,
    required this.type,
    required this.title,
    required this.amountCents,
    required this.memberId,
    required this.notes,
  });

  final String date;
  final FinanceEntryType type;
  final String title;
  final int amountCents;
  final int? memberId;
  final String notes;
}

String _typeLabel(FinanceEntryType type) {
  return switch (type) {
    FinanceEntryType.income => '收入',
    FinanceEntryType.expense => '支出',
    FinanceEntryType.wage => '活动工资',
  };
}

String _formatMoney(int cents) {
  final amount = (cents.abs() / 100).toStringAsFixed(2);
  final sign = cents < 0 ? '−' : '';
  return '$sign¥$amount';
}

DateTime? _parseFinanceDate(String value) {
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

String _formatDate(String value) {
  final date = _parseFinanceDate(value);
  if (date == null) return value.isEmpty ? '日期待定' : value;
  final year = date.year;
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _isoDate(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
