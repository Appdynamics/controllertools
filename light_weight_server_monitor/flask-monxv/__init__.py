from flask import Flask, Response
from flask_sse import sse
import logging

#from gunicorn.http import wsgi
#
#class Response(wsgi.Response):
#    def default_headers(self, *args, **kwargs):
#        headers = super(Response, self).default_headers(*args, **kwargs)
##        L = [h for h in headers if not h.startswith('Server:')]
##        L = [h for h in headers if not h.startswith('Content-Type:')]
#        print('HEADERS=%s'%L)
#        return L
#
#wsgi.Response = Response

def create_app(test_config=None):
    # create and configure the app
    app = Flask(__name__, instance_relative_config=True)

    if test_config is None:
        # load the instance config, if it exists, when not testing
        app.config.from_pyfile('config.py', silent=True)
    else:
        # load the test config if passed in
        app.config.from_mapping(test_config)

    with app.app_context():
        from .site.views import site
        from .api.views import api

#        app.config["REDIS_URL"] = os.environ.get("REDIS_URL")
#        if len(app.config["REDIS_URL"]) == 0:
        app.config["REDIS_URL"] = 'redis://127.0.0.1:6379'          # local default

        app.register_blueprint(site)
        app.register_blueprint(api)
        app.register_blueprint(sse, url_prefix='/stream')

        if __name__ == '__main__':
            app.debug = True
            app.run(threaded=True)
        else:
            gunicorn_logger = logging.getLogger('gunicorn.error')
            app.logger.handlers = gunicorn_logger.handlers
            app.logger.setLevel(gunicorn_logger.level)

        return app

