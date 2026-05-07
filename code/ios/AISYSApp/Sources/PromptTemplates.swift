import Foundation

enum LLMPromptTemplate {
    static func summarize(caseNumber: String, caseName: String, issue: String, holding: String, examPoints: String, ragEvidence: String = "") -> String {
        let issueShort = String(issue.prefix(100))
        let holdingShort = String(holding.prefix(100))
        let ragBlock: String
        if ragEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ragBlock = ""
        } else {
            ragBlock = "\n\n유사판례 근거:\n\(ragEvidence.prefix(500))"
        }
        return """
        다음 한국 판례를 한국어로 요약해줘.
        목적은 강의 대체가 아니라 시험 복습 보조다.
        근거가 부족하면 추정하지 말고 "근거 부족"이라고 써라.

        사건번호: \(caseNumber)
        사건명: \(String(caseName.prefix(80)))
        쟁점: \(issueShort)
        판결: \(holdingShort)
        시험포인트: \(String(examPoints.prefix(100)))\(ragBlock)

        규칙:
        1) 결론 단정은 제공된 근거에서만 작성
        2) 강사 해설처럼 이론 확장 금지, 암기/비교용 문장만 작성
        3) 한줄요약은 90자 이내

        한줄요약:
        핵심쟁점:
        결론:
        포인트:
        """
    }

    static func compare(question: String, evidenceBlock: String) -> String {
        """
        [ROLE]
        You compare precedents based only on evidence for exam study.

        [TASK]
        Compare legal differences relevant to the user question.
        Do not provide lecture-style extended theory.

        [QUESTION]
        \(question)

        [EVIDENCE]
        \(evidenceBlock)

        [RULES]
        1. Mention case_number for every claim.
        2. If conflict exists, describe both positions separately.
        3. If evidence does not support claim, say 'not supported by evidence'.
        4. End with one-line exam trap note.

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
        Focus on confusing points that appear in exams.

        [QUESTION]
        \(question)

        [EVIDENCE]
        \(evidenceBlock)

        [RULES]
        1. Avoid ambiguous options.
        2. Correct answer must be directly supported by evidence.
        3. Include citation in explanation.
        4. Keep each option within 45 Korean characters.

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
        다음 한국 판례에서 OX 퀴즈 \(count)개를 만들어라.

        [근거]
        사건번호: \(caseNumber)
        사건명: \(caseName)
        핵심문장: \(keySentences.prefix(300))
        핵심키워드: \(keywords)

        [규칙]
        1) 정답은 O와 X를 섞어라. 모두 O이면 안 된다.
        2) 진술은 핵심문장/핵심키워드 안의 표현만 사용해라. 새로운 사실을 만들지 마라.
        3) 한 글자/숫자/요건 차이로 헷갈리는 함정 문항을 \(count)개 중 1개 이상 포함해라.
          예: 기한 14일↔10일, 위원장↔부위원장, 유죄↔무죄, 인정↔불인정, 한정↔무제한.
        4) 진술은 100자 이내, 한 줄로 작성해라.
        5) 강의식 해설/이론 확장 금지. 채점용 짧은 해설만 작성해라.
        6) 아래 출력 예시의 단어("진술 1", "진술 2")를 그대로 복사하지 마라. 실제 판례 내용으로 채워라.
        7) 구분자는 정확히 --- 한 줄이다.

        [출력]
        - statement: <문항 1 진술>
        - answer: <O 또는 X>
        - explanation: [\(caseNumber)] 근거 한 줄
        ---
        - statement: <문항 2 진술>
        - answer: <O 또는 X>
        - explanation: [\(caseNumber)] 근거 한 줄
        ---
        """
    }
}
