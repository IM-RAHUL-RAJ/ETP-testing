import os
from pathlib import Path

from flask import Flask, render_template, jsonify
from dotenv import load_dotenv
from analytics_dashboard import AnalyticsDashboard

load_dotenv()

app = Flask(__name__, static_folder='static', template_folder='templates')

BACKEND_URL = os.getenv('BACKEND_URL', 'http://localhost:8085')
AUTH_URL = os.getenv('AUTH_URL', 'http://localhost:3000')
_here = Path(__file__).resolve()
REPO_ROOT = _here.parents[2] if len(_here.parents) > 2 else _here.parent
DUCKDB_PATH = os.getenv('DUCKDB_PATH', str(REPO_ROOT / 'analytics.duckdb'))
DASHBOARD_REFRESH_SECONDS = int(os.getenv('DASHBOARD_REFRESH_SECONDS', '120'))

# Initialize analytics dashboard
dashboard = None

def get_dashboard():
    """Get or initialize analytics dashboard"""
    global dashboard
    if dashboard is None:
        dashboard = AnalyticsDashboard(DUCKDB_PATH)
        dashboard.connect()
    return dashboard

@app.context_processor
def inject_urls():
    return dict(BACKEND_URL=BACKEND_URL, AUTH_URL=AUTH_URL,
                DASHBOARD_REFRESH_SECONDS=DASHBOARD_REFRESH_SECONDS)

@app.route('/')
def index():
    return render_template('register.html')

@app.route('/register')
def register_page():
    return render_template('register.html')

@app.route('/login')
def login_page():
    return render_template('login.html')

@app.route('/dashboard')
def dashboard_page():
    return render_template('dashboard.html')

# Analytics API Routes
@app.route('/api/analytics/available')
def analytics_available():
    """Check if analytics data is available"""
    dash = get_dashboard()
    return jsonify({'available': dash.is_available()})

@app.route('/api/analytics/stats')
def analytics_stats():
    """Get summary statistics"""
    dash = get_dashboard()
    if not dash.is_available():
        return jsonify({'error': 'No analytics data available'}), 404
    
    stats = dash.get_summary_stats()
    return jsonify(stats)

@app.route('/api/analytics/trade-volume')
def trade_volume_chart():
    """Get trade volume data"""
    dash = get_dashboard()
    if not dash.is_available():
        return jsonify({'error': 'No analytics data available'}), 404
    
    data = dash.get_trade_volume()
    if not data:
        return jsonify({'error': 'No trade volume data'}), 404
    return jsonify(data)

@app.route('/api/analytics/fill-rate')
def fill_rate_chart():
    """Get fill rate data"""
    dash = get_dashboard()
    if not dash.is_available():
        return jsonify({'error': 'No analytics data available'}), 404
    
    data = dash.get_fill_rate()
    if not data:
        return jsonify({'error': 'No fill rate data'}), 404
    return jsonify(data)

@app.route('/api/analytics/instrument-exposure')
def instrument_exposure_chart():
    """Get instrument exposure data"""
    dash = get_dashboard()
    if not dash.is_available():
        return jsonify({'error': 'No analytics data available'}), 404
    
    data = dash.get_instrument_exposure()
    if not data:
        return jsonify({'error': 'No instrument exposure data'}), 404
    return jsonify(data)

@app.route('/api/analytics/account-activity')
def account_activity_chart():
    """Get account activity data"""
    dash = get_dashboard()
    if not dash.is_available():
        return jsonify({'error': 'No analytics data available'}), 404
    
    data = dash.get_account_activity()
    if not data:
        return jsonify({'error': 'No account activity data'}), 404
    return jsonify(data)

@app.route('/api/analytics/recent-trades')
def recent_trades():
    """Get most recent trades"""
    dash = get_dashboard()
    if not dash.is_available():
        return jsonify({'error': 'No analytics data available'}), 404
    
    data = dash.get_recent_trades(limit=8)
    if not data:
        return jsonify({'error': 'No recent trades'}), 404
    return jsonify({'trades': data})

@app.route('/analytics')
def analytics_page():
    """Analytics dashboard page (data rendered client-side)"""
    dash = get_dashboard()
    if not dash.is_available():
        return render_template('analytics_unavailable.html')
    
    return render_template('analytics.html',
                         refresh_seconds=DASHBOARD_REFRESH_SECONDS)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=4200, debug=True)
