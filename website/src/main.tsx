import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/global.css';
import { SimDemo } from './components/demo/SimDemo';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <SimDemo />
  </StrictMode>,
);
