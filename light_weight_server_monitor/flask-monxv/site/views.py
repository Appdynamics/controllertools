from flask import Blueprint, render_template, request, Response, stream_with_context, jsonify
from flask_sse import sse
from .. run_cmd import run_cmd
#from .. pubsubsse import announcer, publish_sse
from .. constants import BASH, LOAD_SCRIPT
import time


site = Blueprint('site', __name__)


@site.route('/')
def index():
    return render_template('index.html')


@site.route('/load')
def load():
    return render_template('load.html')


@site.route('/load_data', methods=['POST'])         # intended as Ajax endpoint
def load_data():
    http_code = 0
    if request.method == 'POST':
        cmd = [BASH, LOAD_SCRIPT]
        dirtext = request.form['dirs']
        # clean up list of directories and convert to comma separated
        cleaned_dirs = ','.join([l.strip() for l in dirtext.splitlines() if l.strip() != ''])
        toempty = request.form.get('data-toempty')
        toload = request.form.get('data-toload')
        monitors = request.form.get('mons')
        if toempty == "y":
            cmd.append('-e')
        if toload == 'y':
            cmd.extend(['-d', cleaned_dirs])
        if monitors is not None and len(monitors) > 0:
            cmd.extend(['-m', monitors])
        print('##############################################################################################')
        print(request.form)
        print(cmd)
        for r in run_cmd(cmd):
            sse.publish(r)
            print('LOAD_DATA: just published [%s]' % (r))
            # it appears that rapid messages can exhaust browser's ability to keep up with eventSource onmessage
            # events which seem to be limited to queue of around 512 - hokey fix until I find way of buffering
            # Redis subscribe messages within flask_sse library or something else
            time.sleep(0.09)
        http_code = 200 # this is currently somewhat arbitrary as SSE log output used for error checking
    else:               # currently do nothing for GET
        http_code = 404
    return jsonify({'text': "", 'http_code': http_code})


@site.route('/empty_data')
def empty_data():
    for r in run_cmd2([BASH, LOAD_SCRIPT, '-e']): publish_sse(r)
    return jsonify({'text':"", 'http_code': 200})


@site.route('/columns')
def columns():
    return render_template('columns.html')


@site.route('/process', methods=['POST'])
def process():
    name = request.form['name']
    comment = request.form['comment']
    return 'Name is: ' + name + ' and the comment is: ' + comment


@site.route('/graph')
def sign():
    return render_template('sign.html')


# Publish
@site.route('/publish')
def ping():
    row = request.args.get('row')
    publish_sse(row)
    print('just published >%s<' % row)
    return {}, 200


# Subscribe
#@site.route('/subscribe', methods=['GET'])
#def listen():
#    print("Received GET to /subscribe")
#    def stream():
#        try:
##            messages = announcer.listen()       # creates and returns a queue.Queue
#            messages = announcer.getMsgQ()       # creates and returns a queue.Queue
#            print('In /subscribe: LISTENER retrieved`')
#            while True:
#                msg = messages.get()  # blocks until a new message arrives
#                print('/Subscribe just retrieved & about to yield message >%s<' % msg)
#                yield msg
#                messages.task_done()             # finished with msg
#        except GeneratorExit:
#            print('publisher closed')
#
#    val = Response(stream_with_context(stream()), mimetype='text/event-stream')
#    print('/Subscribe call RETURNing')
#    return val
#

@site.route('/tload', methods=['GET', 'POST'])
def tload():
    return render_template('ajax1.html')


