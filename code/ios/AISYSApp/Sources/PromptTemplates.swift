import Foundation

enum LLMPromptTemplate {
    static func summarize(caseNumber: String, caseName: String, issue: String, holding: String, examPoints: String, ragEvidence: String = "") -> String {
        let issueShort = String(issue.prefix(160))
        let holdingShort = String(holding.prefix(160))
        let ragBlock: String
        if ragEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ragBlock = ""
        } else {
            ragBlock = "\n\n유사판례 근거:\n\(ragEvidence.prefix(400))"
        }
        return """
        한국 경찰/공무원 시험 학습용 판례 카드를 만든다. 강의 대체가 아닌 핸드폰 화면에서 한 번에 이해되는 짧은 카드이다.

        [지시]
        - 한국어로만 출력. 한 줄씩.
        - 근거에 없는 사실 추가 금지. 판단이 부족하면 "근거 부족"이라고 쓴다.
        - 한줄요약: 60자 이내, "[도메인] 사건명 사건. 핵심 쟁점에 관해 결론 방향 판단한 사례." 형식.
        - 핵심쟁점: 한 문장. "...여부." 또는 "...기준."으로 끝낸다.
        - 결론: 한 문장. "...한다." / "...해당한다." / "...위법하다." 등 결과 동사로 끝낸다.
        - 포인트: 키워드 3~5개를 쉼표로 나열. 문장으로 쓰지 마라.

        [예시1]
        사건번호: 2024다311181
        사건명: 영업정지처분취소
        쟁점: 행정청의 영업정지처분이 재량권 일탈·남용에 해당하는지 여부
        판결: 재량권의 행사는 비례원칙과 신뢰보호원칙을 준수해야 하며, 위 처분은 위법하다.
        시험포인트: 재량권, 비례원칙, 신뢰보호

        한줄요약: [행정] 영업정지처분취소 사건. 재량권 일탈·남용 여부에 관해 위법하다고 판단한 사례.
        핵심쟁점: 행정청의 영업정지처분이 재량권 일탈·남용에 해당하는지 여부.
        결론: 비례원칙과 신뢰보호원칙을 위반해 위법하다.
        포인트: 재량권, 비례원칙, 신뢰보호, 행정처분

        [예시2]
        사건번호: 2024도12345
        사건명: 긴급체포 적법성
        쟁점: 형사소송법 제200조의3에 따른 긴급체포의 적법 여부
        판결: 도주 우려와 증거인멸 가능성이 동시에 인정되지 않으면 위법한 체포이다.
        시험포인트: 긴급체포, 영장주의, 도주우려

        한줄요약: [형소법] 긴급체포 적법성 사건. 긴급체포 요건 충족 여부에 관해 위법하다고 판단한 사례.
        핵심쟁점: 형사소송법 제200조의3에 따른 긴급체포가 적법한지 여부.
        결론: 도주우려·증거인멸 가능성이 함께 인정되지 않아 위법한 체포이다.
        포인트: 긴급체포, 영장주의, 도주우려, 증거인멸

        [본문]
        사건번호: \(caseNumber)
        사건명: \(String(caseName.prefix(80)))
        쟁점: \(issueShort)
        판결: \(holdingShort)
        시험포인트: \(String(examPoints.prefix(120)))\(ragBlock)

        [출력]
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
