import requests
import time
import random
import threading

def make_request():
    endpoints = ['/', '/api', '/health']
    while True:
        try:
            response = requests.get(f'http://<YOUR_LOAD_BALANCER_DNS>/{random.choice(endpoints)}', timeout=5)
            print(f"Status: {response.status_code}, Response: {response.text[:50]}")
        except Exception as e:
            print(f"Error: {e}")
        time.sleep(random.uniform(0.1, 1.0))

# Start multiple threads
threads = []
for i in range(10):
    t = threading.Thread(target=make_request)
    t.start()
    threads.append(t)

for t in threads:
    t.join()