#!/usr/bin/env python3
"""Exercise actual Switchboard QML on a temporary Hyprland headless output.
Requires Hyprland, Quickshell, Omarchy and grim. Physical monitor modes and user
configuration are never changed. The temporary output and process are cleaned up.
"""
import argparse, json, os, pathlib, re, subprocess, tempfile, time

REPO = pathlib.Path(__file__).resolve().parents[1]
OMARCHY = pathlib.Path(os.environ.get('OMARCHY_PATH', '/usr/share/omarchy'))
OUTPUT = f'SWITCHBOARD-TEST-{os.getpid()}'
MATRIX = [(1366,768,1), (1920,1080,1), (2560,1440,1.25),
          (2560,1440,1.6), (3840,2160,1.5), (3840,2160,2),
          (1280,720,1), (1080,1920,1), (1920,1080,2), (1280,720,1.6)]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compact', action='store_true', help='Run only the 800x450 effective-size stress cases')
if parser.parse_args().compact: MATRIX = [(1280,720,1.6)]
ARTIFACTS = pathlib.Path(os.environ.get('SWITCHBOARD_TEST_ARTIFACTS', '/tmp/switchboard-matrix-results'))
ARTIFACTS.mkdir(parents=True, exist_ok=True)

def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, **kwargs).strip()

with tempfile.TemporaryDirectory(prefix='switchboard-matrix-') as tmp:
    tmp = pathlib.Path(tmp)
    home = tmp / 'home'; config = home / '.config/omarchy'; config.mkdir(parents=True)
    harness = tmp / 'shell'; harness.mkdir()
    for name in ['Commons', 'Ui']:
        (harness / name).symlink_to(OMARCHY / 'shell' / name, target_is_directory=True)
    for name in ['MenuModel.js','Keybinds.js','UiScale.js','scripts']:
        (harness / name).symlink_to(REPO / name)
    source = (REPO / 'Switchboard.qml').read_text()
    source = source.replace('    id: panel\n', '    id: panel\n    screen: Quickshell.screens.find(s => s.name === ' + json.dumps(OUTPUT) + ') || null\n', 1)
    diagnostics = '''
  function testLayout() {
    var info = JSON.parse(root.scaleInfo())
    info.screenWidth = panel.width
    info.cardX = card.x
    info.anchorCaptured = root.centeredTop >= 0
    info.searchY = card.y + searchBox.mapToItem(card, 0, 0).y
    info.firstResultY = card.y + gridArea.mapToItem(card, 0, 0).y
    info.screenName = panel.screen ? panel.screen.name : ""
    info.gridHeight = gridArea.height
    info.contentHeight = gridFlick.contentHeight
    info.scrollY = gridFlick.contentY
    info.rows = displayModel.count
    info.selectedIndex = root.selectedIndex
    info.footerBottom = hintLabel.parent.mapToItem(card, 0, hintLabel.parent.height).y
    if (displayModel.count > 0) {
      var row = displayModel.get(root.selectedIndex)
      info.selectedTop = row.cellY - gridFlick.contentY
      info.selectedBottom = info.selectedTop + root.tileHeight
    }
    return JSON.stringify(info)
  }
  function testLastRow() {
    // Isolate the keyboard navigation check from host-pointer hover events.
    pointerGate.threshold = 1e9
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, displayModel.count - 1)
    root.revealCursor()
  }
'''
    source = source.replace('  function ping() { return "ok" }', '  function ping() { return "ok" }\n' + diagnostics)
    (harness/'Switchboard.qml').write_text(source)
    (harness/'shell.qml').write_text('''import Quickshell
import Quickshell.Io
import QtQuick
ShellRoot {
  Switchboard { id: launcher }
  IpcHandler {
    target: "test"
    function open(payload: string): void { launcher.open(payload) }
    function filter(query: string): void { launcher.setFilter(query) }
    function dismiss(): void { launcher.close() }
    function layout(): string { return launcher.testLayout() }
    function last(): void { launcher.testLastRow() }
  }
}
''')
    env = os.environ.copy(); env.update(HOME=str(home), XDG_CONFIG_HOME=str(home/'.config'),
        XDG_STATE_HOME=str(home/'.local/state'), OMARCHY_PATH=str(OMARCHY))
    log = (ARTIFACTS/'quickshell.log').open('w')
    process = None; results = []
    def ipc(method, *args):
        return command('quickshell','ipc','-p',str(harness),'call','test',method,*args, env=env)
    def layout():
        return json.loads(ipc('layout'))
    def wait_for(predicate, timeout=8):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:
                info=layout()
                if predicate(info): return info
            except (subprocess.CalledProcessError, json.JSONDecodeError): pass
            time.sleep(.08)
        raise RuntimeError('Timed out waiting for test layout')
    try:
        monitors=json.loads(command('hyprctl','monitors','-j'))
        if not any(m['name']==OUTPUT for m in monitors): command('hyprctl','output','create','headless',OUTPUT)
        process=subprocess.Popen(['quickshell','-p',str(harness)],env=env,stdout=log,stderr=log)
        wait_for(lambda i: i['screenName']==OUTPUT)
        ipc('open',json.dumps({'menu':'root'}))
        for width,height,display_scale in MATRIX:
            command('hyprctl','eval',f'hl.monitor({{ output = "{OUTPUT}", mode = "{width}x{height}@60", position = "8000x0", scale = {display_scale} }})')
            monitor=next(m for m in json.loads(command('hyprctl','monitors','-j')) if m['name']==OUTPUT)
            assert abs(monitor['scale']-display_scale)<.001, f'Compositor substituted scale {monitor["scale"]}'
            expected_w=round(width/display_scale); expected_h=round(height/display_scale)
            wait_for(lambda i: abs(i['screenWidth']-expected_w)<=1 and abs(i['screenHeight']-expected_h)<=1)
            for scale in [1,1.2,2]:
                for alignment in ['top','center']:
                    (config/'shell.json').write_text(json.dumps({'version':1,'bar':{'layout':{'left':[{'id':'krall.switchboard','scale':scale,'verticalAlignment':alignment}]}}}))
                    wait_for(lambda i: i['scale']==scale and i['verticalAlignment']==alignment)
                    for scenario in ['root','search','apps','select','input']:
                        if scenario in ['select','input']:
                            payload={'mode':scenario,'prompt':'Display layout test','width':500,
                                     'options':['\tItem '+str(i)+'\tDetail text' for i in range(60)]}
                        else: payload={'menu': 'apps' if scenario=='apps' else 'root'}
                        ipc('dismiss')
                        ipc('open',json.dumps(payload))
                        opening=wait_for(lambda i: alignment!='center' or i['anchorCaptured'])
                        time.sleep(.14)
                        opening=layout()
                        transition_failures=[]
                        if scenario=='search':
                            # Exercise growth, shrinkage, empty results, and clearing
                            # without closing: final geometry alone misses eye travel.
                            for query in ['s','sc','scr','__no_such_result__','s','scr','']:
                                ipc('filter',query); time.sleep(.10)
                                transition=layout()
                                if alignment=='center' and (abs(transition['searchY']-opening['searchY'])>.5 or abs(transition['firstResultY']-opening['firstResultY'])>.5):
                                    transition_failures.append('typing moved search or first-result position')
                                if transition['cardY']+transition['cardHeight']>transition['screenHeight']+.5 or transition['footerBottom']>transition['cardHeight']+.5:
                                    transition_failures.append('typing overflowed screen or clipped footer')
                            ipc('filter','scr'); time.sleep(.10)
                        info=layout()
                        if info['rows'] and scenario!='input':
                            ipc('last'); time.sleep(.16); info=layout()
                            if info['selectedIndex']!=info['rows']-1:
                                ipc('last'); time.sleep(.16); info=layout()
                        failures=list(set(transition_failures))
                        if info['screenName']!=OUTPUT: failures.append('wrong screen')
                        if info['cardY']<0 or info['cardY']+info['cardHeight']>info['screenHeight']+.5: failures.append('card outside screen')
                        if info['cardWidth']>info['screenWidth']: failures.append('card too wide')
                        if abs(info['cardX']+info['cardWidth']/2-info['screenWidth']/2)>.5: failures.append('not horizontally centered')
                        if alignment=='center' and abs(opening['cardY']+opening['cardHeight']/2-opening['screenHeight']/2)>.5: failures.append('not centered on opening')
                        if info['footerBottom']>info['cardHeight']+.5: failures.append('footer clipped')
                        if scenario!='input' and info['rows']:
                            if info['gridHeight']<=0: failures.append('no list viewport')
                            if info['selectedTop']<-.5 or info['selectedBottom']>info['gridHeight']+.5: failures.append('selected row clipped')
                        result=dict(resolution=f'{width}x{height}', displayScale=display_scale, launcherScale=scale, alignment=alignment,scenario=scenario,failures=failures,**info)
                        results.append(result)
                        if failures or (scale==2 and ((width==1366 and scenario in ['root','apps']) or (width==1280 and display_scale==1.6 and scenario in ['root','apps','select','input']))):
                            name=f'{width}x{height}-{display_scale}-{scale}-{alignment}-{scenario}.png'
                            command('grim','-o',OUTPUT,str(ARTIFACTS/name))
            (ARTIFACTS/'results.json').write_text(json.dumps(results,indent=2)+'\n')
            print(f'Tested {width}x{height} at display scale {display_scale}',flush=True)
    finally:
        if process:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        command('hyprctl','output','remove',OUTPUT)
        log.close()
        (ARTIFACTS/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    failed=[r for r in results if r['failures']]
    runtime_errors=re.findall(r'^.*(?:TypeError|ReferenceError|[Bb]inding loop|failed to load).*$', (ARTIFACTS/'quickshell.log').read_text(), re.MULTILINE)
    for error in runtime_errors: print(error)
    print(f'{len(results)} scenarios, {len(failed)} failures. Artifacts: {ARTIFACTS}',flush=True)
    for r in failed[:15]: print(r['resolution'],r['displayScale'],r['launcherScale'],r['alignment'],r['scenario'],r['failures'])
    raise SystemExit(bool(failed or runtime_errors))
