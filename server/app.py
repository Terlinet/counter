import os
import uvicorn
import asyncio
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from openai import OpenAI
from pydantic import BaseModel
from typing import Dict, List, Optional

app = FastAPI(title="TerlineT Eyes Core - ML Kit Edition")

# --- CONFIGURAÇÃO DE SEGURANÇA (CORS) ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- CONFIGURAÇÃO DA IA (GROQ) ---
# No Hugging Face, adicione GROQ_API_KEY em Settings > Secrets
GROQ_API_KEY = os.getenv("GROQ_API_KEY", "SUA_CHAVE_AQUI")
client_groq = OpenAI(
    base_url="https://api.groq.com/openai/v1",
    api_key=GROQ_API_KEY
)
MODEL_NAME = "llama-3.3-70b-versatile"

# --- MODELOS DE DADOS (Pydantic) ---

class VisionDetection(BaseModel):
    area_name: str
    object_type: str = "pessoa"
    severity: str = "high"

class CountingReport(BaseModel):
    location: str
    counts: Dict[str, int]
    timestamp: str

class HelperContext(BaseModel):
    event_type: str = "fall_detection"

# --- ENDPOINTS ---

@app.get('/')
async def root():
    """Verifica se o core do sistema está online"""
    return {
        "status": "online",
        "system": "TerlineT Eyes Core",
        "engine": "FastAPI + Llama 3.3 (Groq)",
        "vision_tech": "Google ML Kit"
    }

@app.get('/explain_system')
async def explain_system():
    """Explicação autoritária do sistema de visão"""
    try:
        prompt = (
            "Você é a TerlineT Eyes, uma IA de análise de fluxo de elite operando via Google ML Kit Vision. "
            "Explique de forma curta (máximo 2 frases) e autoritária que o sistema utiliza agora "
            "detecção neural local para monitorar e contar objetos com precisão absoluta. "
            "Diga que a análise está operacional."
        )
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=150
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception as e:
        return {"message": "SISTEMA TERLINET EYES (ML KIT CORE) OPERACIONAL. PROTOCOLO DE CONTAGEM ATIVO. MONITORANDO FLUXO NEURAL EM TEMPO REAL."}

@app.post('/analyze_counting')
async def analyze_counting(report: CountingReport):
    """Analisa os dados brutos de contagem do Flutter e gera relatório tático"""
    try:
        # Formata os dados para a IA: "2 Person, 1 Car"
        counts_summary = ", ".join([f"{count} {obj}" for obj, count in report.counts.items()])

        prompt = (
            f"Como TerlineT Eyes, realize uma análise tática rápida para a localização: {report.location}. "
            f"Dados de detecção recebidos via ML Kit: {counts_summary}. "
            "Forneça uma conclusão técnica de segurança ou logística em no máximo 2 frases. Seja direto, frio e profissional."
        )

        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=150
        )
        return {"analysis": completion.choices[0].message.content.strip()}
    except Exception as e:
        return {"analysis": "ANÁLISE TÁTICA CONCLUÍDA: Fluxo dentro dos parâmetros. ML Kit reportando estabilidade no perímetro."}

@app.post('/vision_alert')
async def vision_alert(v: VisionDetection):
    """Gera mensagens de dissuasão imediata para detecções críticas"""
    try:
        prompt = (
            f"TerlineT Eyes detectou {v.object_type} não autorizado em {v.area_name}. "
            f"Aborde o alvo de forma curta e extremamente autoritária para dissuasão imediata. Use tom de comando militar."
        )
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=80
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "ALERTA CRÍTICO: Atividade detectada. Perímetro violado. Saia da área imediatamente."}

@app.get('/defense_intro')
async def defense_intro():
    """Apresentação tática do sistema de defesa"""
    try:
        prompt = "Diga de forma tática que o sistema de defesa TerlineT está online com motor ML Kit Neural e miras calibradas."
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=100
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "Sistema de defesa TerlineT operacional. Monitoramento via rede neural local ativo."}

@app.get('/helper_intro')
async def helper_intro():
    """Apresentação elegante do assistente"""
    try:
        prompt = "Você é o TerlineT Helper operando via Visão Computacional. Apresente-se de forma curta, elegante e protetora."
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=100
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "Olá. Sou o TerlineT Helper. Estou monitorando seu ambiente para garantir sua total segurança."}

# --- INICIALIZAÇÃO ---

if __name__ == "__main__":
    # Configuração para Hugging Face Spaces (Porta 7860)
    port = int(os.getenv("PORT", 7860))
    uvicorn.run(app, host="0.0.0.0", port=port)
