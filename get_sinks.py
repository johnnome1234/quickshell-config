import subprocess
import json
import time

while True:
    try:
        output = subprocess.check_output(['wpctl', 'status'], text=True)
        sinks = []
        in_sinks_section = False
        for line in output.split('\n'):
            if 'Sinks:' in line:
                in_sinks_section = True
                continue
            if in_sinks_section and ('Sources:' in line or 'Video' in line or 'Settings' in line):
                in_sinks_section = False
                continue
            
            if in_sinks_section and '.' in line and '[vol:' in line:
                parts = line.split('.')
                id_str = ''.join(c for c in parts[0] if c.isdigit())
                name_part = parts[1].split('[')[0].strip().lower()
                is_active = '*' in parts[0]
                sinks.append({'id': id_str, 'name': name_part, 'active': is_active})
        
        print(json.dumps(sinks), flush=True)
    except Exception as e:
        pass
    time.sleep(2)

