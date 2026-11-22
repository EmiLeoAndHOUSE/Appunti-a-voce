import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceDiaryApp());
}

class VoiceDiaryApp extends StatelessWidget {
  const VoiceDiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Appunti a Voce',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Color(0xFF0F172A)),
        ),
      ),
      home: const DaysHomeScreen(),
    );
  }
}

// ==========================================
// 1. SCHERMATA PRINCIPALE: GIORNI CON NOTE
// ==========================================
class DaysHomeScreen extends StatefulWidget {
  const DaysHomeScreen({super.key});

  @override
  State<DaysHomeScreen> createState() => _DaysHomeScreenState();
}

class _DaysHomeScreenState extends State<DaysHomeScreen> with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isServiceEnabled = false;
  bool _isSessionActive = false;
  bool _isSpeechListening = false;

  File? _activeFile;
  Timer? _sessionTimer;
  int _sessionSeconds = 0;
  int _sessionWordCount = 0;

  late AnimationController _pulseController;

  Map<String, List<File>> _groupedDays = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _initSpeechEngine();
    _loadFilesFromStorage();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sessionTimer?.cancel();
    _speech.stop();
    super.dispose();
  }

  Future<void> _initSpeechEngine() async {
    _isServiceEnabled = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (err) {
        if (_isSessionActive) {
          Future.delayed(const Duration(milliseconds: 600), _startListeningLoop);
        }
      },
    );
    if (mounted) setState(() {});
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'listening') {
      setState(() => _isSpeechListening = true);
    } else if (status == 'notListening' || status == 'done') {
      setState(() => _isSpeechListening = false);
      if (_isSessionActive) {
        Future.delayed(const Duration(milliseconds: 300), _startListeningLoop);
      }
    }
  }

  Future<void> _loadFilesFromStorage() async {
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final allFiles = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList();

    final Map<String, List<File>> groups = {};
    for (final file in allFiles) {
      final date = file.lastModifiedSync();
      final key = "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
      groups.putIfAbsent(key, () => []).add(file);
    }

    groups.forEach((key, list) {
      list.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    });

    final sortedKeys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final Map<String, List<File>> sortedGroups = {
      for (final k in sortedKeys) k: groups[k]!,
    };

    if (mounted) {
      setState(() {
        _groupedDays = sortedGroups;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleSession() async {
    if (_isSessionActive) {
      await _stopSession();
    } else {
      await _startSession();
    }
  }

  Future<void> _startSession() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permesso microfono necessario per registrare.')),
        );
      }
      return;
    }

    if (!_isServiceEnabled) {
      await _initSpeechEngine();
      if (!_isServiceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Motore vocale non pronto sul telefono.')),
          );
        }
        return;
      }
    }

    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final datePart = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final timePart = "${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}";
    _activeFile = File('${directory.path}/Nota_${datePart}_${timePart}.txt');
    await _activeFile!.writeAsString(
      "--- NOTA VOCALE: ${now.toString().split('.')[0]} ---\n\n",
      flush: true,
    );

    setState(() {
      _isSessionActive = true;
      _sessionSeconds = 0;
      _sessionWordCount = 0;
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isSessionActive) {
        setState(() => _sessionSeconds++);
      }
    });

    _startListeningLoop();
  }

  Future<void> _stopSession() async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _isSessionActive = false;
    await _speech.stop();

    if (_activeFile != null && await _activeFile!.exists()) {
      await _activeFile!.writeAsString(
        "\n--- FINE NOTA ---\n",
        mode: FileMode.append,
        flush: true,
      );
    }

    setState(() {
      _isSpeechListening = false;
    });

    await _loadFilesFromStorage();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nuovo appunto salvato nel giorno di oggi!')),
      );
    }
  }

  void _startListeningLoop() {
    if (!_isSessionActive || _speech.isListening) return;

    _speech.listen(
      localeId: 'it_IT',
      listenMode: stt.ListenMode.dictation,
      listenFor: const Duration(hours: 2),
      pauseFor: const Duration(seconds: 5),
      partialResults: true,
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
          _appendPhraseToDisk(result.recognizedWords.trim());
        }
      },
    );
  }

  Future<void> _appendPhraseToDisk(String phrase) async {
    if (_activeFile == null) return;

    final now = DateTime.now();
    final timeStr = "[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}]";
    final line = "$timeStr $phrase\n\n";

    await _activeFile!.writeAsString(line, mode: FileMode.append, flush: true);
    final words = phrase.split(RegExp(r'\s+')).length;

    if (mounted) {
      setState(() {
        _sessionWordCount += words;
      });
    }
  }

  String _formatDuration(int seconds) {
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatDayLabel(String dateKey) {
    final parts = dateKey.split('-');
    if (parts.length != 3) return dateKey;

    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final day = int.parse(parts[2]);
    final date = DateTime(year, month, day);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(date).inDays;

    final months = [
      '', 'Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
      'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'
    ];
    final weekdays = [
      '', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica'
    ];

    if (diff == 0) {
      return "Oggi, ${day} ${months[month]}";
    } else if (diff == 1) {
      return "Ieri, ${day} ${months[month]}";
    } else {
      return "${weekdays[date.weekday]} ${day} ${months[month]} ${year}";
    }
  }

  int _calculateDaySize(List<File> files) {
    int total = 0;
    for (final f in files) {
      if (f.existsSync()) total += f.lengthSync();
    }
    return total;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appunti a Voce'),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _groupedDays.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: const BoxDecoration(
                              color: Color(0xFFE0F2F1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.mic, size: 48, color: Color(0xFF00796B)),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Nessun appunto registrato',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Premi il pulsante in basso per iniziare. Ogni appunto vocale verrà salvato come file autonomo e organizzato per giorno.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                    itemCount: _groupedDays.keys.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final dayKey = _groupedDays.keys.elementAt(index);
                      final dayFiles = _groupedDays[dayKey]!;
                      final dayTitle = _formatDayLabel(dayKey);
                      final totalSize = _calculateDaySize(dayFiles);

                      return InkWell(
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DayDetailScreen(
                                dayKey: dayKey,
                                dayTitle: dayTitle,
                                initialFiles: dayFiles,
                              ),
                            ),
                          );
                          _loadFilesFromStorage();
                        },
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.02),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE0F2F1),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(Icons.calendar_today_rounded, color: Color(0xFF00796B), size: 24),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      dayTitle,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Text(
                                          '${dayFiles.length} ${dayFiles.length == 1 ? "appunto" : "appunti"}',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF00796B),
                                          ),
                                        ),
                                        Text(
                                          ' • ${_formatBytes(totalSize)}',
                                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400, size: 28),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),

      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isSessionActive)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.red.withOpacity(_pulseController.value * 0.7 + 0.3),
                            ),
                          );
                        },
                      ),
                      Text(
                        'REGISTRAZIONE ATTIVA • ${_formatDuration(_sessionSeconds)} ($_sessionWordCount parole)',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFC62828),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: _toggleSession,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isSessionActive ? const Color(0xFFC62828) : const Color(0xFF00796B),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: Icon(_isSessionActive ? Icons.stop_rounded : Icons.mic_rounded, size: 24),
                  label: Text(
                    _isSessionActive ? 'Arresta e Salva in Oggi' : 'Avvia Nuova Registrazione',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================================================================
// 2. PAGINA DEL GIORNO: ANTEPRIMA DIRETTA DI TUTTI GLI APPUNTI + INVIO
// ===================================================================
class DayDetailScreen extends StatefulWidget {
  final String dayKey;
  final String dayTitle;
  final List<File> initialFiles;

  const DayDetailScreen({
    super.key,
    required this.dayKey,
    required this.dayTitle,
    required this.initialFiles,
  });

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  late List<File> _files;
  final Set<File> _selectedFiles = {};
  final Map<String, String> _fileContents = {};
  final Set<String> _expandedFiles = {}; // Per espandere testi molto lunghi
  bool _isLoadingContent = true;

  @override
  void initState() {
    super.initState();
    _files = List.from(widget.initialFiles);
    _loadFileContents();
  }

  Future<void> _loadFileContents() async {
    for (final file in _files) {
      if (await file.exists()) {
        try {
          String text = await file.readAsString();
          // Pulisce le righe di intestazione/chiusura tecniche per mostrare solo il testo parlato pulito
          text = text.replaceAll(RegExp(r'--- (NOTA VOCALE|APPUNTI VOCALI|INIZIO REGISTRAZIONE).*?---\n*', caseSensitive: false), '');
          text = text.replaceAll(RegExp(r'--- (FINE NOTA|FINE REGISTRAZIONE).*?---\n*', caseSensitive: false), '');
          _fileContents[file.path] = text.trim();
        } catch (_) {
          _fileContents[file.path] = "Impossibile leggere il file.";
        }
      }
    }
    if (mounted) {
      setState(() {
        _isLoadingContent = false;
      });
    }
  }

  void _toggleSelection(File file) {
    setState(() {
      if (_selectedFiles.contains(file)) {
        _selectedFiles.remove(file);
      } else {
        _selectedFiles.add(file);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedFiles.length == _files.length) {
        _selectedFiles.clear();
      } else {
        _selectedFiles.clear();
        _selectedFiles.addAll(_files);
      }
    });
  }

  // Invio delle note selezionate (Multi-selezione WhatsApp / Email)
  void _shareSelectedFiles() {
    if (_selectedFiles.isEmpty) return;

    final xFiles = _selectedFiles.map((f) => XFile(f.path)).toList();
    Share.shareXFiles(
      xFiles,
      subject: '${widget.dayTitle} (${_selectedFiles.length} file .txt)',
      text: 'Ecco i file delle note vocali selezionate del ${widget.dayTitle}.',
    );
  }

  // Invio di tutte le note della giornata insieme
  void _shareAllDayFiles() {
    if (_files.isEmpty) return;
    final xFiles = _files.map((f) => XFile(f.path)).toList();
    Share.shareXFiles(
      xFiles,
      subject: 'Tutti gli appunti del ${widget.dayTitle} (${_files.length} file)',
      text: 'In allegato tutti i file di trascrizione vocale del ${widget.dayTitle}.',
    );
  }

  // Eliminazione note selezionate
  Future<void> _deleteSelectedFiles() async {
    final count = _selectedFiles.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina Note Selezionate'),
        content: Text('Sei sicuro di voler eliminare $count file .txt da questa giornata?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final file in _selectedFiles) {
        if (await file.exists()) {
          await file.delete();
        }
        _files.remove(file);
      }
      _selectedFiles.clear();
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count file eliminati definitivamente.')),
        );
      }
    }
  }

  // Invio rapido WhatsApp singola nota
  void _sendSingleWhatsApp(File file) {
    Share.shareXFiles(
      [XFile(file.path)],
      text: 'Nota vocale del ${widget.dayTitle}',
    );
  }

  // Invio rapido Email singola nota
  void _sendSingleEmail(File file) {
    final timeStr = _formatTime(file.lastModifiedSync());
    Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Appunto Vocale ore $timeStr - ${widget.dayTitle}',
      text: 'In allegato il file di testo .txt della registrazione.',
    );
  }

  // Esporta singola nota o giorno in PDF
  Future<void> _exportPdf(File txtFile) async {
    final content = _fileContents[txtFile.path] ?? await txtFile.readAsString();
    final timeStr = _formatTime(txtFile.lastModifiedSync());
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) => [
          pw.Header(
            level: 0,
            child: pw.Text("Appunto Vocale delle ore $timeStr", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Text("Giorno: ${widget.dayTitle}", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 12),
          pw.Paragraph(text: content, style: const pw.TextStyle(fontSize: 12, lineSpacing: 2)),
        ],
      ),
    );

    final pdfPath = txtFile.path.replaceAll('.txt', '.pdf');
    final pdfFile = File(pdfPath);
    await pdfFile.writeAsBytes(await pdf.save());

    Share.shareXFiles([XFile(pdfFile.path)], subject: 'Appunto PDF ore $timeStr');
  }

  // Elimina singolo file
  Future<void> _deleteSingleFile(File file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina File'),
        content: const Text('Vuoi cancellare definitivamente questo appunto vocale dal telefono?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (await file.exists()) {
        await file.delete();
      }
      setState(() {
        _files.remove(file);
        _selectedFiles.remove(file);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Appunto eliminato.')),
        );
      }
    }
  }

  String _formatTime(DateTime date) {
    return "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}";
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _files.isNotEmpty && _selectedFiles.length == _files.length;
    final hasSelection = _selectedFiles.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(widget.dayTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            Text(
              '${_files.length} ${_files.length == 1 ? "file .txt salvato" : "file .txt salvati"}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          if (_files.isNotEmpty)
            TextButton.icon(
              onPressed: _selectAll,
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all, size: 18, color: const Color(0xFF00796B)),
              label: Text(
                allSelected ? 'Deseleziona' : 'Seleziona tutti',
                style: const TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _isLoadingContent
            ? const Center(child: CircularProgressIndicator())
            : _files.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_open, size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          const Text(
                            'Tutti gli appunti di questa giornata sono stati eliminati.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
                    itemCount: _files.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      final file = _files[index];
                      final isSelected = _selectedFiles.contains(file);
                      final modified = file.lastModifiedSync();
                      final timeStr = _formatTime(modified);
                      final sizeStr = _formatBytes(file.existsSync() ? file.lengthSync() : 0);
                      final content = _fileContents[file.path] ?? "";
                      final isExpanded = _expandedFiles.contains(file.path);
                      final isLong = content.length > 220;

                      return Container(
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFE0F2F1) : Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade200,
                            width: isSelected ? 2.0 : 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.02),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 1. INTESTAZIONE CARD: Spunta di selezione + Orario + Azioni rapide
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                              child: Row(
                                children: [
                                  // Checkbox per la selezione
                                  Checkbox(
                                    value: isSelected,
                                    activeColor: const Color(0xFF00796B),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                                    onChanged: (_) => _toggleSelection(file),
                                  ),
                                  // Orario e Peso
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Ore $timeStr',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: isSelected ? const Color(0xFF004D40) : const Color(0xFF0F172A),
                                          ),
                                        ),
                                        Text(
                                          '${file.uri.pathSegments.last} • $sizeStr',
                                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Azioni rapide singole: WhatsApp & Email & Menu
                                  IconButton(
                                    icon: const Icon(Icons.chat_bubble_outline, color: Color(0xFF25D366), size: 20),
                                    tooltip: 'Invia questa nota su WhatsApp',
                                    onPressed: () => _sendSingleWhatsApp(file),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.email_outlined, color: Color(0xFF1976D2), size: 20),
                                    tooltip: 'Invia questa nota via Email',
                                    onPressed: () => _sendSingleEmail(file),
                                  ),
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                    onSelected: (val) {
                                      if (val == 'pdf') _exportPdf(file);
                                      if (val == 'copy') {
                                        Clipboard.setData(ClipboardData(text: content));
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Testo copiato negli appunti!')),
                                        );
                                      }
                                      if (val == 'delete') _deleteSingleFile(file);
                                    },
                                    itemBuilder: (ctx) => [
                                      const PopupMenuItem(
                                        value: 'pdf',
                                        child: Row(
                                          children: [
                                            Icon(Icons.picture_as_pdf_outlined, color: Colors.red, size: 18),
                                            SizedBox(width: 10),
                                            Text('Esporta come PDF'),
                                          ],
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'copy',
                                        child: Row(
                                          children: [
                                            Icon(Icons.copy, size: 18),
                                            SizedBox(width: 10),
                                            Text('Copia testo'),
                                          ],
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                            SizedBox(width: 10),
                                            Text('Elimina file .txt', style: TextStyle(color: Colors.red)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            // 2. CORPO CARD: ANTEPRIMA DIRETTA DEL TESTO TRASCRITTO
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isSelected ? Colors.white.withOpacity(0.8) : const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText(
                                      content.isEmpty
                                          ? "Nota vuota o senza testo."
                                          : (isLong && !isExpanded ? "${content.substring(0, 220)}..." : content),
                                      style: const TextStyle(
                                        fontSize: 14.5,
                                        height: 1.45,
                                        color: Color(0xFF1E293B),
                                      ),
                                    ),
                                    if (isLong)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              if (isExpanded) {
                                                _expandedFiles.remove(file.path);
                                              } else {
                                                _expandedFiles.add(file.path);
                                              }
                                            });
                                          },
                                          child: Text(
                                            isExpanded ? 'Riduci testo' : 'Leggi tutto...',
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF00796B),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),

      // 3. BARRA IN BASSO: Invio di gruppo o dell'intera giornata
      bottomNavigationBar: _files.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: hasSelection
                    ? Row(
                        children: [
                          // Elimina parziale
                          OutlinedButton.icon(
                            onPressed: _deleteSelectedFiles,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFE53935),
                              side: const BorderSide(color: Color(0xFFE53935), width: 1.5),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            icon: const Icon(Icons.delete_outline, size: 20),
                            label: Text('Elimina (${_selectedFiles.length})'),
                          ),
                          const SizedBox(width: 10),
                          // Invia parziale selezionato
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _shareSelectedFiles,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF00796B),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              icon: const Icon(Icons.share_outlined, size: 20),
                              label: Text(
                                'Invia ${_selectedFiles.length} Selezionati',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      )
                    : SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _shareAllDayFiles,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF00796B),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.share, size: 20),
                          label: Text(
                            'Spedisci Tutte le Note del Giorno (${_files.length})',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
              ),
            ),
    );
  }
}
