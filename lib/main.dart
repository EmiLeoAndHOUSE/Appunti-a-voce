import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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
      title: 'Voice Recorder & Transcriber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
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
  bool _isSessionActive = false; // Se la sessione continua è accesa
  bool _isSpeechListening = false;

  // File attivo su disco: il testo viene scritto in streaming istantaneo su file
  File? _activeFile;
  int _totalBytesWritten = 0;
  int _totalWordCount = 0;
  
  // Timer per durata sessione
  Timer? _sessionTimer;
  int _sessionSeconds = 0;

  // Buffer leggero solo per la visualizzazione a schermo degli ultimi frammenti (Zero memory leak)
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
        // Riavvia automaticamente in caso di timeout silente se la sessione è attiva
        if (_isSessionActive) {
          Future.delayed(const Duration(milliseconds: 600), _startListeningLoop);
        }
      },
    );
    if (mounted) setState(() {});
  }

  // Gestione dello stato continuo (auto-riavvio in caso di pause o silenzi prolungati)
  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'listening') {
      setState(() => _isSpeechListening = true);
    } else if (status == 'notListening' || status == 'done') {
      setState(() => _isSpeechListening = false);
      // Se la sessione continua è ancora attiva, riavvia l'ascolto immediatamente
      if (_isSessionActive) {
        Future.delayed(const Duration(milliseconds: 300), _startListeningLoop);
      }
    }
  }

  // Avvia o arresta l'intera sessione di trascrizione
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
            const SnackBar(content: Text('Motore di riconoscimento vocale non pronto.')),
          );
        }
        return;
      }
    }

    // Crea un nuovo file su disco dove appendere il testo in streaming (poca RAM)
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _activeFile = File('${directory.path}/trascrizione_$timestamp.txt');
    await _activeFile!.writeAsString(
      "--- INIZIO REGISTRAZIONE: ${DateTime.now().toString().split('.')[0]} ---\n\n",
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
        "\n--- FINE REGISTRAZIONE: ${DateTime.now().toString().split('.')[0]} ---\n",
        mode: FileMode.append,
        flush: true,
      );
      _totalBytesWritten = _activeFile!.lengthSync();
    }

    setState(() {
      _isSpeechListening = false;
      _currentSpokenSentence = "";
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sessione completata e salvata su disco!')),
      );
    }
  }

  // Loop di ascolto in background/foreground
  void _startListeningLoop() {
    if (!_isSessionActive || _speech.isListening) return;

    _speech.listen(
      localeId: 'it_IT',
      listenMode: stt.ListenMode.dictation,
      listenFor: const Duration(hours: 2), // Durata massima per blocco
      pauseFor: const Duration(seconds: 5),  // Pausa di silenzio prima di chiudere la frase
      partialResults: true,
      onResult: (result) {
        setState(() {
          _currentSpokenSentence = result.recognizedWords;
        });

        // Appena una frase è definitiva, scrivila DIRETTAMENTE su disco (Zero accumulo RAM)
        if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
          _appendPhraseToDisk(result.recognizedWords.trim());
        }
      },
    );
  }

  // Scrittura in streaming su disco a basso consumo
  Future<void> _appendPhraseToDisk(String phrase) async {
    if (_activeFile == null) return;

    final now = DateTime.now();
    final timeStr = "[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}]";
    final line = "$timeStr $phrase\n\n";

    // Scrive subito sul file con flush (libera immediatamente la memoria RAM)
    await _activeFile!.writeAsString(line, mode: FileMode.append, flush: true);

    final words = phrase.split(RegExp(r'\s+')).length;

    setState(() {
      _totalBytesWritten = _activeFile!.lengthSync();
      _totalWordCount += words;
      _currentSpokenSentence = "";

      // Conserva a video solo gli ultimi 5 eventi per evitare spreco di memoria UI
      _recentLog.insert(0, "$timeStr $phrase");
      if (_recentLog.length > 5) {
        _recentLog.removeLast();
      }
    });
  }

  // Visualizza l'intero file salvato
  Future<void> _viewSavedFile() async {
    if (_activeFile == null || !await _activeFile!.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun file attivo salvato finora.')),
      );
      return;
    }

    final content = await _activeFile!.readAsString();
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
                  const Text('Testo Completo su Disco', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              Text(
                'File: ${_activeFile!.path.split('/').last} • ${_formatBytes(_totalBytesWritten)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: SelectableText(
                    content.isEmpty ? "Nessun testo registrato finora." : content,
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

  // Condivisione rapida del file TXT
  Future<void> _shareTxt() async {
    if (_activeFile == null || !await _activeFile!.exists()) return;
    Share.shareXFiles([XFile(_activeFile!.path)], text: 'Trascrizione vocale');
  }

  // Generazione del PDF on-demand dal file TXT (senza tenerlo in memoria permanente)
  Future<void> _exportPdf() async {
    if (_activeFile == null || !await _activeFile!.exists()) return;

    final content = await _activeFile!.readAsString();
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) => [
          pw.Header(
            level: 0,
            child: pw.Text("Trascrizione Vocale", style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Text("Generato il: ${DateTime.now().toString().split('.')[0]}", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 12),
          pw.Paragraph(
            text: content,
            style: const pw.TextStyle(fontSize: 12, lineSpacing: 2),
          ),
        ],
      ),
    );

    final pdfPath = _activeFile!.path.replaceAll('.txt', '.pdf');
    final pdfFile = File(pdfPath);
    await pdfFile.writeAsBytes(await pdf.save());

    if (mounted) {
      Share.shareXFiles([XFile(pdfFile.path)], text: 'Trascrizione PDF');
    }
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
        title: const Text('Voice Recorder Streamer'),
        centerTitle: true,
        actions: [
          if (_activeFile != null)
            IconButton(
              icon: const Icon(Icons.remove_red_eye_outlined),
              tooltip: 'Leggi file completo',
              onPressed: _viewSavedFile,
            ),
        ],
      ),
      body: Column(
        children: [
          // Statistiche a basso consumo (Zero memory footprint)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            color: colorScheme.surfaceVariant.withOpacity(0.4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem('Durata', _formatDuration(_sessionSeconds), Icons.timer_outlined),
                _buildStatItem('Occupazione Disco', _formatBytes(_totalBytesWritten), Icons.storage_outlined),
                _buildStatItem('Parole', '$_totalWordCount', Icons.text_snippet_outlined),
              ],
            ),
          ),

          // Area centrale: monitor live delle parole attuali + log leggero
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Box live frase in corso
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
                                  ? (_isSpeechListening ? "🎙️ Ascolto in corso..." : "In attesa di voce...")
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
                                  ? "Parla adesso: il testo verrà scritto istantaneamente su disco..."
                                  : "Premi il pulsante in basso per avviare la sessione."),
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

                  // Lista leggera delle ultime frasi
                  Expanded(
                    child: _recentLog.isEmpty
                        ? const Center(
                            child: Text(
                              'Nessuna frase ancora trascritta.\nOgni frase pronunciata viene salvata direttamente sul file .txt',
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

                  // Pulsanti esportazione / Condivisione
                  if (_activeFile != null)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.share),
                            label: const Text('Invia .TXT a PC'),
                            onPressed: _shareTxt,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('Esporta in PDF'),
                            onPressed: _exportPdf,
                          ),
                        ),
                      ],
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
          _isSessionActive ? 'Arresta Sessione' : 'Avvia Registrazione Continua',
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
