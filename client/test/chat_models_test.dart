import 'package:chatgpt_bridge_client/src/model/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses rich message.delta SSE events', () {
    final event = BridgeEvent(
      data: <String, dynamic>{
        'type': 'message.delta',
        'text': 'hello',
      },
    );

    expect(event.delta, 'hello');
  });

  test('resolves branch position by message id when node_id is absent', () {
    final conversation = ChatConversation.fromJson(<String, dynamic>{
      'id': 'conv',
      'title': 'Branches',
      'current_node': 'a2',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'answer-2',
          'role': 'assistant',
          'text': 'second',
        },
      ],
      'nodes': <String, dynamic>{
        'u1': <String, dynamic>{
          'parent': 'root',
          'children': <String>['a1', 'a2'],
          'message': <String, dynamic>{
            'id': 'question',
            'role': 'user',
            'text': 'question',
          },
        },
        'a1': <String, dynamic>{
          'parent': 'u1',
          'children': <String>[],
          'message': <String, dynamic>{
            'id': 'answer-1',
            'role': 'assistant',
            'text': 'first',
          },
        },
        'a2': <String, dynamic>{
          'parent': 'u1',
          'children': <String>[],
          'message': <String, dynamic>{
            'id': 'answer-2',
            'role': 'assistant',
            'text': 'second',
          },
        },
      },
    });

    final branch = conversation.branchPositionFor(conversation.messages.single);
    expect(branch, isNotNull);
    expect(branch!.index, 1);
    expect(branch.previousNode, 'a1');
    expect(branch.hasNext, isFalse);
  });

  test('preserves research reports and citations', () {
    final conversation = ChatConversation.fromJson(<String, dynamic>{
      'id': 'conv',
      'title': 'Research',
      'messages': <dynamic>[],
      'research_reports': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'r1',
          'text': 'Report',
          'citations': <Map<String, dynamic>>[
            <String, dynamic>{
              'url': 'https://example.com',
              'title': 'Example',
            },
          ],
        },
      ],
    });

    expect(conversation.researchReports.single.text, 'Report');
    expect(
      conversation.researchReports.single.citations.single.url,
      'https://example.com',
    );
  });

  test('retains block-only generated image messages', () {
    final conversation = ChatConversation.fromJson(<String, dynamic>{
      'id': 'conv',
      'title': 'Image',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'image-message',
          'role': 'assistant',
          'text': '',
          'blocks': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'image',
              'asset_pointer': 'sediment://file-123',
              'mime_type': 'image/png',
              'name': 'generated.png',
            },
          ],
        },
      ],
    });

    expect(conversation.messages, hasLength(1));
    expect(conversation.messages.single.assets, hasLength(1));
    expect(conversation.messages.single.assets.single.isImage, isTrue);
    expect(
      conversation.messages.single.assets.single.pointer,
      'sediment://file-123',
    );
  });

  test('lifts and deduplicates citations from rich blocks', () {
    final message = ChatMessage.fromJson(<String, dynamic>{
      'id': 'answer',
      'role': 'assistant',
      'text': 'Answer',
      'citations': <Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'https://example.com',
          'title': 'Example',
        },
      ],
      'blocks': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'citations',
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'url': 'https://example.com',
              'title': 'Example',
            },
          ],
        },
      ],
    });

    expect(message.citations, hasLength(1));
    expect(message.citations.single.title, 'Example');
  });

  test('retains code-only messages', () {
    final conversation = ChatConversation.fromJson(<String, dynamic>{
      'id': 'conv',
      'title': 'Code',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'code-message',
          'role': 'assistant',
          'blocks': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'code',
              'code': 'print("hello")',
              'language': 'python',
            },
          ],
        },
      ],
    });

    expect(conversation.messages, hasLength(1));
    expect(conversation.messages.single.blocks.single['type'], 'code');
  });
}
