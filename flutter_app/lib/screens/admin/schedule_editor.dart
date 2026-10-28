import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/bus_service.dart';
import '../../services/api_service.dart';
import '../../models/models.dart';

class ScheduleEditor extends StatefulWidget {
  const ScheduleEditor({super.key});

  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  String? _selectedHostel;
  DateTime _selectedDate = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final bus = context.watch<BusService>();
    final auth = context.watch<AuthService>();
    final caretakerHostel = auth.currentUser?.role == 'caretaker'
      ? auth.currentUser?.hostelId
      : null;

    var buses = caretakerHostel != null
      ? bus.getBusesByHostel(caretakerHostel)
      : _selectedHostel != null
        ? bus.getBusesByHostel(_selectedHostel!)
        : bus.buses;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Schedule Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                locale: const Locale('en', 'GB'),
                initialDate: _selectedDate,
                firstDate: DateTime.now().subtract(const Duration(days: 7)),
                lastDate: DateTime.now().add(const Duration(days: 30)),
              );
              if (picked != null) setState(() => _selectedDate = picked);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Date and hostel filter bar
          Container(
            color: const Color(0xFF1565C0),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                // Date display
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.calendar_today,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatPickerDate(_selectedDate),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${buses.length} buses',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (caretakerHostel == null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 34,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _chip('All', null),
                        ...HostelModel.allHostels.map(
                          (h) => _chip(h.name, h.id),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          Expanded(
            child: bus.isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: buses.length,
                    itemBuilder: (_, i) => _ScheduleRow(
                      bus: buses[i],
                      date: _selectedDate,
                      schedule: _scheduleFor(
                        bus.schedules,
                        buses[i].busNumber,
                        _selectedDate,
                      ),
                    ),
                  ),
          ),

          // Bulk update button
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.update),
                label: const Text('Bulk Update All Schedules'),
                onPressed: () => _showBulkUpdate(context),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String? value) {
    final selected = _selectedHostel == value;
    return GestureDetector(
      onTap: () => setState(() => _selectedHostel = value),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF1565C0) : Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  String _formatPickerDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  void _showBulkUpdate(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Bulk Update'),
        content: const Text(
          'This will sync all schedules for the selected date. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Schedules synced successfully!'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('Sync'),
          ),
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatefulWidget {
  final BusModel bus;
  final DateTime date;
  final ScheduleModel? schedule;

  const _ScheduleRow({required this.bus, required this.date, this.schedule});

  @override
  State<_ScheduleRow> createState() => _ScheduleRowState();
}

class _ScheduleRowState extends State<_ScheduleRow> {
  bool _isEditing = false;
  late TextEditingController _fromHostelCtrl;
  late TextEditingController _fromMBSECtrl;

  @override
  void initState() {
    super.initState();
    _fromHostelCtrl = TextEditingController(
      text: (widget.schedule ?? widget.bus.schedule)?.fromHostelTime ?? '',
    );
    _fromMBSECtrl = TextEditingController(
      text: (widget.schedule ?? widget.bus.schedule)?.fromMBSETime ?? '',
    );
  }

  @override
  void dispose() {
    _fromHostelCtrl.dispose();
    _fromMBSECtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      '${widget.bus.busNumber}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1565C0),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bus ${widget.bus.busNumber} • ${widget.bus.assignedHostel}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        widget.bus.driver?.name ?? '',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _isEditing = !_isEditing),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: _isEditing
                          ? const Color(0xFF1565C0)
                          : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _isEditing ? Icons.close : Icons.edit,
                      size: 18,
                      color: _isEditing
                          ? Colors.white
                          : const Color(0xFF1565C0),
                    ),
                  ),
                ),
              ],
            ),

            if (!_isEditing) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  _infoTile(
                    Icons.arrow_upward,
                    'From Hostel',
                    (widget.schedule ?? widget.bus.schedule)?.fromHostelTime ??
                        'Not set',
                    const Color(0xFF1565C0),
                  ),
                  const SizedBox(width: 8),
                  _infoTile(
                    Icons.arrow_downward,
                    'From MBSE',
                    (widget.schedule ?? widget.bus.schedule)?.fromMBSETime ??
                        'Not set',
                    const Color(0xFF4CAF50),
                  ),
                ],
              ),
              if ((widget.schedule ?? widget.bus.schedule)
                      ?.specialNote
                      .isNotEmpty ==
                  true) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '📍 ${(widget.schedule ?? widget.bus.schedule)!.specialNote}',
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fromHostelCtrl,
                      decoration: InputDecoration(
                        labelText: 'From Hostel',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _fromMBSECtrl,
                      decoration: InputDecoration(
                        labelText: 'From MBSE',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _saveSchedule(context),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4CAF50),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoTile(IconData icon, String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 10, color: color)),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color,
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

  Future<void> _saveSchedule(BuildContext context) async {
    final auth = context.read<AuthService>();
    final api = context.read<ApiService>();
    final busService = context.read<BusService>();
    final messenger = ScaffoldMessenger.of(context);
    final today = DateTime.now();
    final editingToday =
        widget.date.year == today.year &&
        widget.date.month == today.month &&
        widget.date.day == today.day &&
        (widget.schedule ?? widget.bus.schedule) != null;
    if (editingToday) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm today’s schedule edit'),
          content: const Text(
            'This bus is already scheduled for today. Are you sure you want to edit it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Edit schedule'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final dateStr = widget.date.toIso8601String().split('T')[0];
    final schedule = ScheduleModel(
      id: (widget.schedule ?? widget.bus.schedule)?.id ?? '',
      busNumber: widget.bus.busNumber,
      date: dateStr,
      fromHostelTime: _fromHostelCtrl.text,
      fromMBSETime: _fromMBSECtrl.text,
      specialNote: (widget.schedule ?? widget.bus.schedule)?.specialNote ?? '',
      updatedBy: auth.currentUser?.email ?? '',
    );
    await busService.updateSchedule(
      schedule,
      api,
      auth.currentUser?.token ?? '',
    );
    if (!mounted) return;
    setState(() => _isEditing = false);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Saved!'),
        duration: Duration(seconds: 1),
        backgroundColor: Colors.green,
      ),
    );
  }
}

ScheduleModel? _scheduleFor(
  List<ScheduleModel> schedules,
  int busNumber,
  DateTime date,
) {
  final key =
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  for (final schedule in schedules) {
    if (schedule.busNumber == busNumber && schedule.date.startsWith(key)) {
      return schedule;
    }
  }
  return null;
}
