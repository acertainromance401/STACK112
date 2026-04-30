import Foundation

enum LLMPromptTemplate {
    static func summarize(caseNumber: String, caseName: String, issue: String, holding: String, examPoints: String) -> String {
        """
        [ROLE]
        You are a legal study assistant for Korean police exam preparation.

        [TASK]
        Summarize the precedent in plain Korean with exam focus.

        [RULES]
        1. Use only provided evidence fields.
        2. If evidence is insufficient, explicitly state uncertainty.
        3. Do not invent statute numbers, dates, or holdings.
        4. Output format must follow exactly.

        [EVIDENCE]
        case_number: \(caseNumber)
        case_name: \(caseName)
        issue_summary: \(issue)
        holding_summary: \(holding)
        exam_points: \(examPoints)

        [OUTPUT]
        - one_line_summary:
        - key_issue:
        - ruling_point:
        - exam_takeaway:
        """
    }

    static func compare(question: String, evidenceBlock: String) -> String {
        """
        [ROLE]
        You compare precedents based only on evidence.

        [TASK]
        Compare legal differences relevant to the user question.

        [QUESTION]
        \(question)

        [EVIDENCE]
        \(evidenceBlock)

        [RULES]
        1. Mention case_number for every claim.
        2. If conflict exists, describe both positions separately.
        3. If evidence does not support claim, say 'not supported by evidence'.

        [OUTPUT]
        - common_points:
        - differences:
        - likely_exam_trap:
        - citations: [case_number list]
        """
    }

    static func quiz(question: String, evidenceBlock: String) -> String {
        """
        [ROLE]
        You generate one multiple-choice quiz from evidence only.

        [TASK]
        Create one 4-choice item with one correct answer and explanation.

        [QUESTION]
        \(question)

        [EVIDENCE]
        \(evidenceBlock)

        [RULES]
        1. Avoid ambiguous options.
        2. Correct answer must be directly supported by evidence.
        3. Include citation in explanation.

        [OUTPUT]
        - prompt:
        - options:
          1)
          2)
          3)
          4)
        - correct_index: (0-3)
        - explanation:
        - citations: [case_number list]
        """
    }

    /// OX 퀴즈 생성 프롬프트
    /// 출력 형식: 문항마다 "---" 구분자 사용
    static func oxQuiz(caseNumber: String, caseName: String, keySentences: String, keywords: String, count: Int) -> String {
        """
        판례 OX 퀴즈 \(count)개를 만들어라.

        사건번호: \(caseNumber)
        사건명: \(caseName)
        핵심문장: \(keySentences.prefix(300))

        규칙: O와 X를 섞어라. 구분자는 --- 이다.

        출력형식:
        - statement: 한국어 진술
        - answer: O
        - explanation: \(caseNumber) 판례에서 도출
        ---
        - statement: 한국어 진술
        - answer: X
        - explanation: \(caseNumber) 판례와 다른 내용
        ---
        """
    }
}
