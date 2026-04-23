import psycopg2, random, os
conn = psycopg2.connect(host=os.environ['DB_HOST'], dbname=os.environ['DB_NAME'], user=os.environ['DB_USER'], password=os.environ['DB_PASSWORD'])
cur = conn.cursor()
for i in range(100):
    cur.execute("INSERT INTO claims (member_id, amount, description, status, created_at) VALUES (%s, %s, %s, %s, current_date)", ('MBR' + str(random.randint(1000,9999)), round(random.uniform(50, 8000), 2), 'test claim', 'pending'))
conn.commit()
print('100 test claims inserted for today')
