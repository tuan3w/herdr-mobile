import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/words/agent_names.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/data/words/plural.dart';
import 'package:herdr_mobile/data/words/where_line.dart';

void main() {
  group('counts', () {
    test('one, many and none agree with the number', () {
      expect(countOf(1, 'subagent'), '1 subagent');
      expect(countOf(2, 'subagent'), '2 subagents');
      expect(countOf(0, 'agent'), '0 agents');
      expect(countOf(3, 'match', 'matches'), '3 matches');
      expect(needYou(1), '1 needs you');
      expect(needYou(4), '4 need you');
      expect(needYou(10, noun: 'agent'), '10 agents need you');
      expect(needYou(1, noun: 'agent'), '1 agent needs you');
    });
  });

  group('elapsed', () {
    test('compact steps at each unit boundary', () {
      expect(Elapsed.compact(const Duration(seconds: 59)), '59s');
      expect(Elapsed.compact(const Duration(seconds: 59), seconds: false), '<1m');
      expect(Elapsed.compact(const Duration(seconds: 60)), '1m');
      expect(Elapsed.compact(const Duration(minutes: 59)), '59m');
      expect(Elapsed.compact(const Duration(minutes: 60)), '1h');
      expect(Elapsed.compact(const Duration(minutes: 65)), '1h 05m');
      expect(Elapsed.compact(const Duration(hours: 23, minutes: 59)), '23h 59m');
      expect(Elapsed.compact(const Duration(hours: 24)), '1d');
      expect(Elapsed.compact(const Duration(seconds: -5)), '0s');
    });

    test('words spell units out and agree in number', () {
      expect(Elapsed.words(const Duration(seconds: 1)), '1 second');
      expect(Elapsed.words(const Duration(minutes: 2)), '2 minutes');
      expect(Elapsed.words(const Duration(minutes: 65)), '1 hour 5 minutes');
      expect(Elapsed.words(const Duration(days: 3, hours: 2)), '3 days');
    });
  });

  group('moments', () {
    final now = DateTime(2026, 1, 1, 0, 30);

    test('ago crosses midnight and the year', () {
      expect(formatAgo(now.subtract(const Duration(seconds: 20)), now), 'Just now');
      expect(formatAgo(now.subtract(const Duration(minutes: 20)), now), '20m ago');
      expect(formatAgo(DateTime(2025, 12, 31, 23, 50), now), '40m ago', reason: 'minutes win over the calendar');
      expect(formatAgo(DateTime(2025, 12, 31, 22), now), 'Yesterday', reason: 'hours across midnight are yesterday');
      expect(formatAgo(DateTime(2025, 12, 28, 12), now), '4d ago');
      expect(formatAgo(DateTime(2025, 10, 3, 9), now), '3 Oct 2025');
      expect(formatAgo(now.add(const Duration(minutes: 5)), now), 'Just now');
    });

    test('when, as a label and inside a sentence', () {
      final noon = DateTime(2026, 3, 10, 12);
      expect(formatWhen(DateTime(2026, 3, 10, 9, 5), noon), 'Today 09:05');
      expect(formatWhen(DateTime(2026, 3, 9, 14, 2), noon), 'Yesterday 14:02');
      expect(formatWhen(DateTime(2026, 2, 3, 14, 2), noon), '3 Feb, 14:02');
      expect(formatWhen(DateTime(2025, 2, 3, 14, 2), noon), '3 Feb 2025, 14:02');
      expect(formatWhen(DateTime(2026, 3, 10, 9, 5), noon, sentence: true), 'today at 09:05');
      expect(formatWhen(DateTime(2026, 3, 9, 14, 2), noon, sentence: true), 'yesterday at 14:02');
      expect(formatWhen(DateTime(2026, 2, 3, 14, 2), noon, sentence: true), 'on 3 Feb at 14:02');
    });

    // Only bites where the clock changes; run with TZ=Europe/London.
    test('the day after a clock change is still yesterday', () {
      final now = DateTime(2026, 3, 30, 1);
      final before = DateTime(2026, 3, 29, 14, 2);
      expect(formatWhen(before, now), 'Yesterday 14:02');
      expect(formatAgo(before, now), 'Yesterday');
    });
  });

  group('names', () {
    test('an agent has one name everywhere', () {
      expect(agentName('claude'), 'Claude Code');
      expect(agentName('codex'), 'Codex');
      expect(agentName('omp'), 'omp');
      expect(agentName('pi'), 'pi');
      expect(agentName('dsh'), 'dsh');
      expect(agentName('aider'), 'aider', reason: 'an unknown kind is shown as it came');
      expect(agentName(null), 'Shell');
      expect(agentName(' '), 'Shell');
    });

    test('the known agents are omp, Codex, Claude Code, pi and dsh', () {
      expect(knownAgents.map((a) => a.id), ['omp', 'codex', 'claude', 'pi', 'dsh']);
      expect(knownAgents.map((a) => a.label), ['omp', 'Codex', 'Claude Code', 'pi', 'dsh']);
      for (final agent in knownAgents) {
        expect(agentName(agent.id), agent.label, reason: '${agent.id} keeps its name');
      }
      expect(knownAgentLabel('aider'), isNull, reason: 'an unknown kind has no label of its own');
    });
  });

  group('where line', () {
    test('each part says something the title does not', () {
      expect(
        whereLine(agent: 'Claude Code', machine: 'studio-mac', folder: 'payments-api', title: 'Fix the parser'),
        'Claude Code · studio-mac · payments-api',
      );
      expect(whereLine(agent: 'Claude Code', machine: 'mac', folder: 'api', title: 'Claude Code'), 'mac · api');
      expect(whereLine(agent: 'Codex', machine: 'mac', folder: 'api', showMachine: false), 'Codex · api');
      expect(
        whereLine(agent: 'Codex', folder: 'api', workspace: 'api'),
        'Codex · api',
        reason: 'folder equal to workspace: said once',
      );
      expect(
        whereLine(agent: 'Codex', folder: 'api', workspace: 'main'),
        'Codex · api',
        reason: 'the folder wins over the workspace',
      );
      expect(
        whereLine(agent: 'Codex', workspace: 'infra'),
        'Codex · infra',
        reason: 'workspace only without a folder',
      );
      expect(
        whereLine(folder: 'api', title: 'API'),
        '',
        reason: 'nothing left to say',
      );
    });
  });
}
