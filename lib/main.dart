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
  runApp(const VoiceTranscriberApp());
}

class VoiceTranscriberApp extends StatelessWidget {
  const VoiceTranscriberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Appunti a Voce',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          primary: Colors.teal.shade700,
        ),
        useMaterial3: true,
      ),
      home: const TranscriberScreen(),
    );
  }
}

class TranscriberScreen extends StatefulWidget {
  const TranscriberScreen({super.key});

  @override
  State<TranscriberScreen> createState() => _TranscriberScreenState();
}

class _TranscriberScreenState extends State<TranscriberScreen> {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isServiceEnabled = false;
  bool _isSessionActive = false;
  bool _isSpeechListening = false;

  File? _activeFile;
  int _totalBytesWritten = 0;
  int _totalWordCount = 0;

  Timer? _sessionTimer;
  int _sessionSeconds = 0;

  String _currentSpokenSentence = "";
  final List<String> _recentLog = [];

  @override
  void initState() {
    super.initState();
    _initSpeechEngine();
  }

  @override
  void dispose() {
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
          const SnackBar(content: Text('Permesso microfono necessario.')),
        );
      }
      return;
    }

    if (!_isServiceEnabled) {
      await _initSpeechEngine();
      if (!_isServiceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Motore vocale non pronto sul dispositivo.')),
          );
        }
        return;
      }
    }

    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _activeFile = File('${directory.path}/nota_$timestamp.txt');
    await _activeFile!.writeAsString(
      "--- APPUNTI VOCALI: ${DateTime.now().toString().split('.')[0]} ---\n\n",
      flush: true,
    );

    setState(() {
      _isSessionActive = true;
      _sessionSeconds = 0;
      _totalBytesWritten = _activeFile!.lengthSync();
      _totalWordCount = 0;
      _currentSpokenSentence = "";
      _recentLog.clear();
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
        "\n--- FINE NOTA: ${DateTime.now().toString().split('.')[0]} ---\n",
        mode: FileMode.append,
        flush: true,
      );
      _totalBytesWritten = _activeFile!.lengthSync();
    }

    setState(() {
      _isSpeechListening = false;
      _currentSpokenSentence = "";
    });

    // Mostra subito il pannello di condivisione WhatsApp / Email / PDF al termine
    if (mounted && _activeFile != null) {
      _showShareBottomSheet(_activeFile!);
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
        setState(() {
          _currentSpokenSentence = result.recognizedWords;
        });

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

    setState(() {
      _totalBytesWritten = _activeFile!.lengthSync();
      _totalWordCount += words;
      _currentSpokenSentence = "";

      _recentLog.insert(0, "$timeStr $phrase");
      if (_recentLog.length > 5) {
        _recentLog.removeLast();
      }
    });
  }

  // --- PANNELLO DI CONDIVISIONE WHATSAPP, EMAIL, PDF ---
  void _showShareBottomSheet(File file) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.share, color: Colors.teal),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Condividi Trascrizione',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${file.path.split('/').last} • ${_formatBytes(file.lengthSync())}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 1. WhatsApp
            _buildShareOption(
              icon: Icons.chat_bubble_outline,
              iconColor: const Color(0xFF25D366), // WhatsApp Green
              title: 'Invia tramite WhatsApp',
              subtitle: 'Invia il file .txt a una chat o gruppo WhatsApp',
              onTap: () {
                Navigator.pop(ctx);
                Share.shareXFiles(
                  [XFile(file.path)],
                  text: 'Ecco il file con gli appunti vocali trascriti.',
                );
              },
            ),

            const SizedBox(height: 10),

            // 2. Email
            _buildShareOption(
              icon: Icons.email_outlined,
              iconColor: Colors.blue.shade700,
              title: 'Invia tramite Email',
              subtitle: 'Apre l\'app di posta con il file .txt in allegato',
              onTap: () {
                Navigator.pop(ctx);
                Share.shareXFiles(
                  [XFile(file.path)],
                  subject: 'Trascrizione Vocale: ${DateTime.now().toString().split('.')[0]}',
                  text: 'In allegato il file di testo con la trascrizione della registrazione vocale.',
                );
              },
            ),

            const SizedBox(height: 10),

            // 3. Genera ed Invia PDF
            _buildShareOption(
              icon: Icons.picture_as_pdf_outlined,
              iconColor: Colors.red.shade700,
              title: 'Invia come documento PDF',
              subtitle: 'Converte la nota in PDF impaginato e lo condivide',
              onTap: () async {
                Navigator.pop(ctx);
                await _shareAsPdf(file);
              },
            ),

            const SizedBox(height: 10),

            // 4. Copia Testo negli Appunti
            _buildShareOption(
              icon: Icons.copy,
              iconColor: Colors.grey.shade700,
              title: 'Copia solo il Testo',
              subtitle: 'Copia l\'intero contenuto per incollarlo dove vuoi',
              onTap: () async {
                Navigator.pop(ctx);
                final text = await file.readAsString();
                await Clipboard.setData(ClipboardData(text: text));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Testo copiato negli appunti!')),
                  );
                }
              },
            ),

            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Chiudi'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareOption({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Future<void> _shareAsPdf(File txtFile) async {
    final content = await txtFile.readAsString();
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) => [
          pw.Header(
            level: 0,
            child: pw.Text("Appunti Vocali", style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Text("Data: ${DateTime.now().toString().split('.')[0]}", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 12),
          pw.Paragraph(
            text: content,
            style: const pw.TextStyle(fontSize: 12, lineSpacing: 2),
          ),
        ],
      ),
    );

    final pdfPath = txtFile.path.replaceAll('.txt', '.pdf');
    final pdfFile = File(pdfPath);
    await pdfFile.writeAsBytes(await pdf.save());

    Share.shareXFiles(
      [XFile(pdfFile.path)],
      subject: 'Appunti Vocali PDF',
      text: 'In allegato il file PDF generato.',
    );
  }

  // Visualizza anteprima testo file
  Future<void> _viewSavedFile(File file) async {
    if (!await file.exists()) return;
    final content = await file.readAsString();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Anteprima Testo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              Text(
                '${file.path.split('/').last} • ${_formatBytes(file.lengthSync())}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: SelectableText(
                    content.isEmpty ? "Nessun testo registrato." : content,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- SCHERMATA ARCHIVIO REGISTRAZIONI ---
  void _openArchiveScreen() async {
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArchiveScreen(
          files: files,
          onShare: _showShareBottomSheet,
          onView: _viewSavedFile,
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appunti a Voce', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: 'Archivio Trascrizioni',
            onPressed: _openArchiveScreen,
          ),
          if (_activeFile != null)
            IconButton(
              icon: const Icon(Icons.remove_red_eye_outlined),
              tooltip: 'Leggi file attivo',
              onPressed: () => _viewSavedFile(_activeFile!),
            ),
        ],
      ),
      body: Column(
        children: [
          // Barra Statistiche in tempo reale
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            color: colorScheme.surfaceVariant.withOpacity(0.4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem('Durata', _formatDuration(_sessionSeconds), Icons.timer_outlined),
                _buildStatItem('Occupazione', _formatBytes(_totalBytesWritten), Icons.storage_outlined),
                _buildStatItem('Parole', '$_totalWordCount', Icons.text_snippet_outlined),
              ],
            ),
          ),

          // Area centrale
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _isSessionActive ? Colors.teal.shade50 : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _isSessionActive ? Colors.teal.shade300 : Colors.grey.shade300,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _isSessionActive ? Icons.mic : Icons.mic_off,
                              size: 18,
                              color: _isSessionActive ? Colors.teal : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isSessionActive
                                  ? (_isSpeechListening ? "🎙️ Ascolto continuo..." : "In attesa di voce...")
                                  : "Microfono disattivato",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _isSessionActive ? Colors.teal.shade800 : Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _currentSpokenSentence.isNotEmpty
                              ? _currentSpokenSentence
                              : (_isSessionActive
                                  ? "Parla adesso: il testo viene salvato in streaming sul file..."
                                  : "Premi il pulsante in basso per avviare la registrazione."),
                          style: TextStyle(
                            fontSize: 16,
                            fontStyle: _currentSpokenSentence.isEmpty ? FontStyle.italic : FontStyle.normal,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  const Text('Ultime frasi scritte su disco:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 8),

                  Expanded(
                    child: _recentLog.isEmpty
                        ? const Center(
                            child: Text(
                              'Nessuna frase ancora trascritta.\nLe frasi vengono scritte direttamente nel file .txt',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: 13),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _recentLog.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6.0),
                                child: Text(_recentLog[index], style: const TextStyle(fontSize: 13, height: 1.3)),
                              );
                            },
                          ),
                  ),

                  if (_activeFile != null)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      icon: const Icon(Icons.share),
                      label: const Text('Condividi (WhatsApp / Email / PDF)', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () => _showShareBottomSheet(_activeFile!),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleSession,
        backgroundColor: _isSessionActive ? Colors.red.shade700 : Colors.teal.shade700,
        icon: Icon(_isSessionActive ? Icons.stop : Icons.fiber_manual_record, color: Colors.white),
        label: Text(
          _isSessionActive ? 'Arresta e Condividi' : 'Avvia Registrazione Continua',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 20, color: Colors.teal.shade700),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

// --- SCHERMATA ARCHIVIO FILE SALVATI ---
class ArchiveScreen extends StatefulWidget {
  final List<File> files;
  final Function(File) onShare;
  final Function(File) onView;

  const ArchiveScreen({
    super.key,
    required this.files,
    required this.onShare,
    required this.onView,
  });

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  late List<File> _fileList;

  @override
  void initState() {
    super.initState();
    _fileList = List.from(widget.files);
  }

  void _deleteFile(File file) async {
    await file.delete();
    setState(() {
      _fileList.remove(file);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File eliminato.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Archivio Note Vocali'),
      ),
      body: _fileList.isEmpty
          ? const Center(
              child: Text('Nessuna nota vocale salvata nell\'archivio.'),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _fileList.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final file = _fileList[index];
                final date = file.lastModifiedSync();
                final dateStr =
                    "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
                final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);

                return Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.description, color: Colors.teal),
                    ),
                    title: Text(
                      file.path.split('/').last,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    subtitle: Text('$dateStr • $sizeKb KB', style: const TextStyle(fontSize: 12)),
                    onTap: () => widget.onView(file),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.share, color: Colors.teal),
                          tooltip: 'Condividi (WhatsApp / Email)',
                          onPressed: () => widget.onShare(file),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          tooltip: 'Elimina',
                          onPressed: () => _deleteFile(file),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
