#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Tue May  3 18:44:19 2025

@author: acertainromance401
"""

import nltk
import pandas as pd
from nltk.tokenize import word_tokenize
from nltk.stem import WordNetLemmatizer
import string
import numpy as np
from bs4 import BeautifulSoup
from sklearn.metrics.pairwise import euclidean_distances, cosine_similarity

# NLTK 리소스 다운로드
nltk.download('punkt')
nltk.download('wordnet')
nltk.download('omw-1.4')
nltk.download('punkt_tab') # punkt가 다운로드 되지 않는 경우가 생겨서 추가

# XML 데이터 불러오기 경로 복사, 붙여넣기
df = pd.read_xml("/Users/acertainromance401/Desktop/25-1/정보검색/2025_정보검색_프로젝트과제/Posts.xml")

# 필요한 열 선택 및 전처리
cleaned_posts_df = df[['Id','PostTypeId','ParentId','Title','Body']].copy()
cleaned_posts_df['Title'] = cleaned_posts_df['Title'].fillna('')
cleaned_posts_df['Body'] = cleaned_posts_df['Body'].fillna('')
cleaned_posts_df['Title'] = cleaned_posts_df['Title'].apply(lambda x: BeautifulSoup(x, 'html.parser').get_text())
cleaned_posts_df['Body'] = cleaned_posts_df['Body'].apply(lambda x: BeautifulSoup(x, 'html.parser').get_text())

# 전처리 도구
punctuation = string.punctuation + "‘’“”"
lemmatizer = WordNetLemmatizer()

def clean_tokenize_lemmatize(text):
    text = text.lower()
    for p in punctuation:
        text = text.replace(p, '')
    tokens = word_tokenize(text)
    lemmatized = [lemmatizer.lemmatize(token) for token in tokens]
    return ' '.join(lemmatized)

# 텍스트 정제
cleaned_posts_df['Cleaned_Title'] = cleaned_posts_df['Title'].apply(clean_tokenize_lemmatize)
cleaned_posts_df['Cleaned_Body'] = cleaned_posts_df['Body'].apply(clean_tokenize_lemmatize)

# 질문/답변 분리 및 병합
questions = cleaned_posts_df[cleaned_posts_df['PostTypeId'] == 1][['Id', 'Cleaned_Title', 'Cleaned_Body']]
answers = cleaned_posts_df[cleaned_posts_df['PostTypeId'] == 2][['ParentId', 'Cleaned_Body']]
answers_grouped = answers.groupby('ParentId')['Cleaned_Body'].apply(lambda x: ' '.join(x)).reset_index()
answers_grouped.columns = ['Id', 'All_Answers']
merged_df = questions.merge(answers_grouped, on='Id', how='inner')
merged_df['Posting'] = merged_df['Cleaned_Title'] + ' ' + merged_df['Cleaned_Body'] + ' ' + merged_df['All_Answers']
merged_postings_df = merged_df[['Id', 'Posting']]

# 쿼리 설정
# 질문1, 질문2에 사용되는 쿼리
query_list = ['espresso', 'turkish coffee', 'persian coffee']

# 질문3에 사용되는 쿼리
#query_list = ['espresso', 'turkish coffee', 'making a decaffeinated coffee', 'can I use the same coffee grounds twice?']

#결과 이상치 확인용
#query_list = ['turkish', 'coffee', 'turkish coffee', 'persian coffee']
all_queries_tf_list = []
result = []


# df4 == term-frequency

df4 = merged_postings_df.copy()

df4_list = []

for q in query_list:
    cleaned_query = clean_tokenize_lemmatize(q)
    query_words = cleaned_query.split()

    term_frequency = []

    word_list = []

    for i in df4['Posting']:
        tokens = i.split()
        count = sum(tokens.count(word) for word in query_words)
        term_frequency.append(count)

        word_frequency = {word: tokens.count(word) for word in query_words}
        word_list.append(word_frequency)


    df_tmp = merged_postings_df.copy()
    df_tmp['Query'] = q
    df_tmp['Query_Frequency'] = term_frequency
    df_tmp['Query_Term_Frequencies'] = word_list

    df4_list.append(df_tmp)


    top5 = df_tmp[df_tmp['Query_Frequency'] > 0].sort_values(by='Query_Frequency', ascending=False).head(5)
    top5 = top5[['Id', 'Query_Frequency', 'Posting']].copy()
    top5['Query'] = q
    top5['Rank'] = range(1, len(top5) + 1)
    result.append(top5)

# 모든 쿼리 결과 병합
df4 = pd.concat(df4_list, ignore_index=True)

table = pd.concat(result)
table = table[['Query','Rank','Query_Frequency','Id','Posting']]
table_output = table.copy()
table_output['Posting'] = table_output['Posting'].apply(lambda x: ' '.join(x.split()[:20]) + '...')

print("\n--- Term Frequency(Query_Frequency)기반 Ranking 생성 ---")

print(table_output.to_string(index = False))

# TF 계산
for q in query_list:
    cleaned_query = clean_tokenize_lemmatize(q)
    query_words = cleaned_query.split()
    term_frequency = []
    word_list = []

    for i in merged_postings_df['Posting']:
        tokens = i.split()
        count = sum(tokens.count(word) for word in query_words)
        term_frequency.append(count)
        word_frequency = {word: tokens.count(word) for word in query_words}
        word_list.append(word_frequency)

    df_tmp = merged_postings_df.copy()
    df_tmp['Query'] = q
    df_tmp['Query_Frequency'] = term_frequency
    df_tmp['Query_Term_Frequencies'] = word_list
    all_queries_tf_list.append(df_tmp)

    top5 = df_tmp[df_tmp['Query_Frequency'] > 0].sort_values(by='Query_Frequency', ascending=False).head(5)
    top5 = top5[['Id', 'Query_Frequency', 'Posting']].copy()
    top5['Query'] = q
    top5['Rank'] = range(1, len(top5) + 1)
    result.append(top5)

# TF 테이블
all_queries_tf_df = pd.concat(all_queries_tf_list, ignore_index=True)
all_queries_tf_df['Posting'] = all_queries_tf_df['Posting'].apply(lambda x: ' '.join(x.split()))
all_queries_tf_df['words_count'] = all_queries_tf_df['Posting'].apply(lambda x: len(x.split()))
TF = all_queries_tf_df.copy()
TF['TF'] = TF['Query_Frequency'] / TF['words_count']
TF = TF[['Id','Posting','Query','TF']]

# Weight 계산 (log scale)
weight_list = []
for w in TF['TF']:
    if w > 0:
        weight_list.append(np.log(1 + w))
    else:
        weight_list.append(0)
weight = pd.DataFrame(weight_list)
TF = pd.concat([TF, weight], axis=1)
TF.columns = ['Id', 'Posting', 'Query', 'TF', 'Weight']

# DF 계산
df5 = merged_postings_df.copy()
query_doc_count = []
for q in query_list:
    cleaned_query = clean_tokenize_lemmatize(q)
    query_words = cleaned_query.split()
    doc_frequency = []
    for i in df5['Posting']:
        tokens = i.split()
        doc_frequency.append(int(any(word in tokens for word in query_words)))
    df5['Document_Frequency'] = doc_frequency
    count = sum(doc_frequency)
    query_doc_count.append({'Query': q, 'Document_Frequency': count})
DF = pd.DataFrame(query_doc_count)

# IDF 계산
total_docs = len(merged_postings_df)
idf_values = []
for count in DF['Document_Frequency']:
    idf = np.log2(total_docs / count)
    idf_values.append(idf)
DF['IDF'] = idf_values

# TF-IDF 계산
TF_IDF = TF.merge(DF[['Query', 'IDF']], on='Query', how='left')
TF_IDF['TF_IDF'] = TF_IDF['TF'] * TF_IDF['IDF']

# TF-IDF 기반 상위 5개 문서 추출
top_docs_by_tfidf = TF_IDF[TF_IDF['TF_IDF'] > 0].copy()
top_docs_by_tfidf = top_docs_by_tfidf.sort_values(by=['Query', 'TF_IDF'], ascending=[True, False])
top_docs_by_tfidf = top_docs_by_tfidf.groupby('Query').head(5)
top_docs_by_tfidf['Rank'] = top_docs_by_tfidf.groupby('Query').cumcount() + 1
top_docs_by_tfidf_output = top_docs_by_tfidf.copy()
top_docs_by_tfidf_output['Posting'] = top_docs_by_tfidf['Posting'].apply(lambda x: ' '.join(x.split()[:20]) + '...')

# 최종 테이블
tfidf_table = top_docs_by_tfidf_output[['Query', 'Rank', 'TF_IDF', 'Id', 'Posting']].copy()
tfidf_table = tfidf_table.sort_values(by=['Query', 'Rank'])

# 출력
print("--- TF-IDF (Query-Specific IDF) Ranking ---")
print(tfidf_table.to_string(index=False))


# --- 전체 어휘집 기반 Bag-of-Words TF-IDF 벡터 생성 ---
print("\n--- 전체 어휘집 기반 Bag-of-Words TF-IDF 벡터 생성 ---")

# 1. 모든 문서에서 토큰 리스트 생성
all_postings_tokens = [posting.split() for posting in merged_postings_df['Posting']]

# 2. 전체 어휘집 생성 (정렬된 리스트로)
flat_list = [item for sublist in all_postings_tokens for item in sublist]
vocabulary = sorted(list(set(flat_list)))
# word_to_idx = {word: idx for idx, word in enumerate(vocabulary)} # tfidf_bow_df 컬럼명으로 vocabulary 리스트 직접 사용
vocab_size = len(vocabulary)
num_documents = len(merged_postings_df)

print(f"전체 어휘집 크기: {vocab_size}")
print(f"전체 문서 수: {num_documents}")

# 3. DF (Document Frequency) 계산
# 각 단어가 등장하는 문서의 수를 저장할 Series 초기화 (인덱스는 vocabulary)
df_counts = pd.Series(np.zeros(vocab_size, dtype=int), index=vocabulary)
for tokens_in_doc in all_postings_tokens:
    unique_tokens_in_doc = set(tokens_in_doc)
    for token in unique_tokens_in_doc:
        if token in df_counts.index: # 어휘집에 있는 단어인지 확인
            df_counts[token] += 1

# 4. IDF (Inverse Document Frequency) 계산
# IDF = log((N + 1) / (df + 1)) + 1 (Scikit-learn TfidfTransformer 기본값과 유사)
# N은 전체 문서 수. df_counts도 vocabulary 순서에 따름.
idf_values = np.log((num_documents + 1) / (df_counts + 1)) + 1

# 5. TF-IDF 행렬 생성
tfidf_matrix = np.zeros((num_documents, vocab_size))
doc_ids = merged_postings_df['Id'].tolist()

for doc_idx, posting_text in enumerate(merged_postings_df['Posting']):
    tokens = posting_text.split()

    if not tokens:
        continue

    doc_len = len(tokens)

    term_counts_in_doc = pd.Series(np.zeros(vocab_size), index=vocabulary) # 현 문서의 단어 빈도 (어휘집 기준)
    for token in tokens:
        if token in term_counts_in_doc.index:
            term_counts_in_doc[token] += 1

    tf_values_in_doc = term_counts_in_doc / doc_len

    # TF-IDF: TF * IDF (element-wise, pandas Series가 인덱스 기준으로 자동 정렬 연산)
    tfidf_vector_for_doc = tf_values_in_doc * idf_values

    tfidf_matrix[doc_idx, :] = tfidf_vector_for_doc.values

# TF-IDF 행렬을 DataFrame으로 변환
tfidf_bow_df = pd.DataFrame(tfidf_matrix, index=doc_ids, columns=vocabulary)

vsm_results_euclidean = []
vsm_results_cosine = []

# 미리 계산된 문서 TF-IDF 벡터 (tfidf_bow_df)
# 미리 계산된 IDF 값 (idf_values - Series, vocabulary 순서)
# 전체 어휘집 (vocabulary - list)

for query_text in query_list:
    # 1. 쿼리 전처리 및 TF-IDF 벡터화
    cleaned_query = clean_tokenize_lemmatize(query_text)
    query_tokens = cleaned_query.split()

    if not query_tokens: # 빈 쿼리는 건너뛰기
        print(f"\n쿼리 '{query_text}'가 비어있어 건너뜁니다.")
        continue

    query_len = len(query_tokens)

    # 쿼리의 TF 계산 (어휘집 기준)
    query_term_counts = pd.Series(np.zeros(vocab_size), index=vocabulary)
    for token in query_tokens:
        if token in query_term_counts.index: # 어휘집에 있는 단어인지 확인
            query_term_counts[token] += 1

    query_tf_values = query_term_counts / query_len

    # 쿼리 TF-IDF 벡터 계산 (미리 계산된 IDF 사용)
    query_tfidf_vector = query_tf_values * idf_values # idf_values는 vocabulary와 동일한 인덱스를 가짐
    query_tfidf_vector = query_tfidf_vector.fillna(0) # IDF 계산 시 분모가 0이 되어 NaN이 된 경우 0으로 처리 (어휘집에는 있지만 DF가 0인 경우 등)

    query_vector_reshaped = query_tfidf_vector.values.reshape(1, -1) # scikit-learn 함수 입력을 위해 2D로 변환

    if np.all(query_vector_reshaped == 0):
        print(f"\n쿼리 '{query_text}'의 TF-IDF 벡터가 모두 0입니다. (어휘집에 없는 단어로만 구성)")
        # 이 경우 유사도/거리가 의미 없을 수 있으나, 일단 진행 (결과는 대부분 0 또는 최대 거리)
        # 빈 결과 리스트를 추가하거나, 에러 처리를 할 수 있음

    # 2. Euclidean Distance 계산 및 랭킹
    # tfidf_bow_df.values 는 (num_documents, vocab_size) 형태의 numpy 배열
    # euclidean_distances는 각 문서 벡터와 쿼리 벡터 간의 거리를 반환 (값이 작을수록 유사)
    distances = euclidean_distances(tfidf_bow_df.values, query_vector_reshaped)
    # distances는 (num_documents, 1) 형태의 배열. 1D로 변환.
    distances_flat = distances.flatten()

    # 거리를 포함한 DataFrame 생성
    doc_scores_euclidean = pd.DataFrame({
        'Id': tfidf_bow_df.index,
        'Distance': distances_flat
    })

    # 원본 Posting 정보 병합 (상위 결과에만 필요하므로, 정렬 후 병합)
    # merged_postings_df에는 'Id'와 원본 'Posting'이 있음

    # 거리가 짧은 순으로 정렬, 상위 5개 선택
    top5_euclidean = doc_scores_euclidean.sort_values(by='Distance', ascending=True).head(5)
    top5_euclidean = top5_euclidean.merge(merged_postings_df[['Id', 'Posting']], on='Id', how='left')
    top5_euclidean['Query'] = query_text
    top5_euclidean['Rank'] = range(1, len(top5_euclidean) + 1)
    top5_euclidean['Posting'] = top5_euclidean['Posting'].apply(lambda x: ' '.join(x.split()[:20]) + '...')
    vsm_results_euclidean.append(top5_euclidean[['Query', 'Rank', 'Distance', 'Id', 'Posting']])

    # 3. Cosine Similarity 계산 및 랭킹
    # cosine_similarity는 각 문서 벡터와 쿼리 벡터 간의 코사인 유사도를 반환 (값이 클수록 유사)
    similarities = cosine_similarity(tfidf_bow_df.values, query_vector_reshaped)
    # similarities는 (num_documents, 1) 형태의 배열. 1D로 변환.
    similarities_flat = similarities.flatten()

    doc_scores_cosine = pd.DataFrame({
        'Id': tfidf_bow_df.index,
        'Cosine_Similarity': similarities_flat
    })

    # 유사도가 높은 순으로 정렬, 상위 5개 선택
    top5_cosine = doc_scores_cosine.sort_values(by='Cosine_Similarity', ascending=False).head(5)
    top5_cosine = top5_cosine.merge(merged_postings_df[['Id', 'Posting']], on='Id', how='left')
    top5_cosine['Query'] = query_text
    top5_cosine['Rank'] = range(1, len(top5_cosine) + 1)
    top5_cosine['Posting'] = top5_cosine['Posting'].apply(lambda x: ' '.join(x.split()[:20]) + '...')
    vsm_results_cosine.append(top5_cosine[['Query', 'Rank', 'Cosine_Similarity', 'Id', 'Posting']])

# 결과 취합 및 출력
if vsm_results_euclidean:
    final_euclidean_table = pd.concat(vsm_results_euclidean, ignore_index=True)
    print("\n--- VSM Ranking (Euclidean Distance) --- Top 5 ---")
    print(final_euclidean_table.to_string(index=False))
else:
    print("\nEuclidean Distance 기반 VSM 랭킹 결과가 없습니다.")

if vsm_results_cosine:
    final_cosine_table = pd.concat(vsm_results_cosine, ignore_index=True)
    print("\n--- VSM Ranking (Cosine Similarity) --- Top 5 ---")
    print(final_cosine_table.to_string(index=False))
else:
    print("\nCosine Similarity 기반 VSM 랭킹 결과가 없습니다.")