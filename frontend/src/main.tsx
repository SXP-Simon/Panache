import { createRoot } from 'react-dom/client';
import App from './App';
import { initializePwa } from './pwa';
import './style.css';
const root = document.getElementById('app');
if (!root) throw new Error('The application root is missing');
initializePwa();
createRoot(root).render(<App />);
